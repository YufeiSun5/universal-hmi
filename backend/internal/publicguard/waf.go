// Package publicguard adapts the pinned Coraza engine to bounded public requests.
// It never buffers responses or retains a transaction across an SSE response.
package publicguard

import (
	"bytes"
	"embed"
	"encoding/json"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/corazawaf/coraza/v3"
)

const passwordTargetControl = `
SecRule REQUEST_METHOD "@streq POST" "id:10001,phase:1,pass,nolog,chain"
 SecRule REQUEST_FILENAME "@rx ^/api/v1/(auth/login|security/mfa/begin)$" "t:none,chain"
 SecRule REQUEST_HEADERS:Content-Type "@streq application/json" "t:none,ctl:ruleRemoveTargetByTag=OWASP_CRS;ARGS:json.password"
`

type Engine struct{ baseline, credentials coraza.WAF }

//go:embed rules
var ruleAssets embed.FS

// io/fs paths use '/', including when Coraza's configuration directory was
// formed with Windows filepath.Join. Never fall back to the host filesystem.
type embeddedRules struct{ fs.FS }

func (f embeddedRules) Open(name string) (fs.File, error) {
	return f.FS.Open(strings.ReplaceAll(name, "\\", "/"))
}
func (f embeddedRules) ReadFile(name string) ([]byte, error) {
	return fs.ReadFile(f.FS, strings.ReplaceAll(name, "\\", "/"))
}
func (f embeddedRules) Glob(pattern string) ([]string, error) {
	return fs.Glob(f.FS, strings.ReplaceAll(pattern, "\\", "/"))
}

func New() (*Engine, error) {
	rules, err := fs.Sub(ruleAssets, "rules")
	if err != nil {
		return nil, err
	}
	build := func(exception string) (coraza.WAF, error) {
		return coraza.NewWAF(coraza.NewWAFConfig().WithRootFS(embeddedRules{rules}).WithDirectives(`
Include @coraza.conf-recommended
SecRuleEngine On
SecAuditEngine Off
SecDebugLogLevel 0
SecRequestBodyLimit 65536
SecRequestBodyNoFilesLimit 65536
SecRequestBodyInMemoryLimit 65536
SecRequestBodyLimitAction Reject
SecResponseBodyAccess Off
` + exception + `
Include @crs-setup.conf.example
Include @owasp_crs/REQUEST-*.conf
`))
	}
	baseline, err := build("")
	if err != nil {
		return nil, err
	}
	credentials, err := build(passwordTargetControl)
	if err != nil {
		return nil, err
	}
	return &Engine{baseline: baseline, credentials: credentials}, nil
}

// credentialShape gates a narrowly scoped password-value exception. Every other
// argument, JSON key, query value, body parser and protocol rule remains active.
func credentialShape(data []byte, login bool) bool {
	if !utf8.Valid(data) {
		return false
	}
	d := json.NewDecoder(bytes.NewReader(data))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return false
	}
	seen := map[string]bool{}
	for d.More() {
		token, err = d.Token()
		if err != nil {
			return false
		}
		key, ok := token.(string)
		if !ok || seen[key] {
			return false
		}
		seen[key] = true
		var value json.RawMessage
		if d.Decode(&value) != nil {
			return false
		}
		switch key {
		case "password", "username", "code", "captcha_id", "captcha_answer":
			if key != "password" && !login {
				return false
			}
			var text string
			if len(value) == 0 || value[0] != '"' || json.Unmarshal(value, &text) != nil {
				return false
			}
		case "issue_token":
			if !login || !(bytes.Equal(value, []byte("true")) || bytes.Equal(value, []byte("false"))) {
				return false
			}
		default:
			return false
		}
	}
	token, err = d.Token()
	return err == nil && token == json.Delim('}') && d.Decode(new(any)) == io.EOF && seen["password"] && (!login || seen["username"])
}

// Inspect returns only a fixed decision, never matched input or engine errors.
// The owned body is replayed exactly after the transaction has been closed.
func (e *Engine) Inspect(r *http.Request) (owned []byte, decision string) {
	if len(r.URL.RequestURI()) > 16384 || len(r.Header) > 64 {
		return nil, "request_limit"
	}
	headerBytes := len(r.Host)
	for name, values := range r.Header {
		if len(values) > 32 {
			return nil, "request_limit"
		}
		for _, value := range values {
			headerBytes += len(name) + len(value)
		}
	}
	if headerBytes > 32768 {
		return nil, "request_limit"
	}
	if r.Body != nil {
		defer r.Body.Close()
		var err error
		owned, err = io.ReadAll(io.LimitReader(r.Body, 65537))
		if err != nil {
			return nil, "body_read_error"
		}
		if len(owned) > 65536 {
			return nil, "body_limit"
		}
	}
	waf := e.baseline
	exact := r.URL.EscapedPath() == r.URL.Path && (r.URL.Path == "/api/v1/auth/login" || r.URL.Path == "/api/v1/security/mfa/begin")
	if r.Method == "POST" && exact && len(r.Header.Values("Content-Type")) == 1 && r.Header.Get("Content-Type") == "application/json" {
		if !credentialShape(owned, r.URL.Path == "/api/v1/auth/login") {
			return nil, "credential_shape_invalid"
		}
		query, err := url.ParseQuery(r.URL.RawQuery)
		if err != nil {
			return nil, "query_invalid"
		}
		for name := range query {
			if strings.EqualFold(name, "password") || strings.EqualFold(name, "json.password") {
				return nil, "credential_query_alias"
			}
		}
		waf = e.credentials
	}
	tx := waf.NewTransaction()
	defer func() {
		if tx.Close() != nil {
			owned = nil
			decision = "transaction_close_error"
		}
	}()
	host, port, _ := net.SplitHostPort(r.RemoteAddr)
	peerPort, _ := strconv.Atoi(port)
	tx.ProcessConnection(host, peerPort, "", 443)
	tx.ProcessURI(r.URL.RequestURI(), r.Method, r.Proto)
	tx.SetServerName(r.Host)
	tx.AddRequestHeader("Host", r.Host)
	if r.Header.Get("Content-Length") == "" && r.ContentLength >= 0 && len(r.TransferEncoding) == 0 && (r.ContentLength > 0 || r.Method == "POST") {
		tx.AddRequestHeader("Content-Length", strconv.FormatInt(r.ContentLength, 10))
	}
	for name, values := range r.Header {
		for _, value := range values {
			tx.AddRequestHeader(name, value)
		}
	}
	for _, value := range r.TransferEncoding {
		tx.AddRequestHeader("Transfer-Encoding", value)
	}
	if tx.ProcessRequestHeaders() != nil {
		return nil, "blocked_headers"
	}
	reader := bytes.NewReader(owned)
	if interruption, _, err := tx.ReadRequestBodyFrom(reader); err != nil {
		return nil, "body_parse_error"
	} else if interruption != nil {
		return nil, "blocked_body"
	}
	if reader.Len() != 0 {
		return nil, "uninspected_remainder"
	}
	if interruption, err := tx.ProcessRequestBody(); err != nil {
		return nil, "body_parse_error"
	} else if interruption != nil {
		return nil, "blocked_body"
	}
	return owned, "allowed"
}
