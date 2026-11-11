// Package publicguard adapts the pinned Coraza engine to bounded public requests.
// It never buffers responses or retains a transaction across an SSE response.
package publicguard

import (
	"bytes"
	"embed"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/runtimewire"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"regexp"
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

type Engine struct{ baseline, credentials, maintenance, photos, development, runtime coraza.WAF }

var photoPost = regexp.MustCompile(`^/api/v1/equipment/[A-Za-z0-9_-]+/photos$`)

var maintenancePut = regexp.MustCompile(`^/api/v1/(security/(users|roles)/[A-Za-z0-9_-]+|equipment-navigation)$`)
var maintenanceDelete = regexp.MustCompile(`^/api/v1/(security/roles/[A-Za-z0-9_-]+|equipment/[A-Za-z0-9_-]+/photos/[A-Za-z0-9_-]+)$`)

func maintenanceMethod(r *http.Request) bool {
	return r.URL.EscapedPath() == r.URL.Path &&
		(r.Method == "PUT" && maintenancePut.MatchString(r.URL.Path) ||
			r.Method == "DELETE" && maintenanceDelete.MatchString(r.URL.Path))
}

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
	maintenance, err := build(`SecAction "id:10002,phase:1,pass,nolog,setvar:'tx.allowed_methods=GET HEAD POST OPTIONS PUT DELETE'"`)
	if err != nil {
		return nil, err
	}
	photos, err := build("SecRequestBodyLimit 3145728\nSecRequestBodyNoFilesLimit 3145728\nSecRequestBodyInMemoryLimit 3145728")
	if err != nil {
		return nil, err
	}
	development, err := build(`
SecRequestBodyAccess Off
SecRequestBodyLimit 33554432
SecRequestBodyNoFilesLimit 33554432
SecRequestBodyInMemoryLimit 33554432
SecAction "id:10003,phase:1,pass,nolog,setvar:'tx.allowed_methods=GET HEAD POST OPTIONS PUT DELETE'"
`)
	if err != nil {
		return nil, err
	}
	runtime, err := build(`
SecRequestBodyAccess Off
SecRequestBodyLimit 1048576
SecRequestBodyNoFilesLimit 1048576
SecRequestBodyInMemoryLimit 1048576
SecAction "id:10004,phase:1,pass,nolog,setvar:'tx.allowed_request_content_type=|application/grpc-web+proto| |application/grpc+proto| |application/grpc|'"
`)
	if err != nil {
		return nil, err
	}
	return &Engine{baseline: baseline, credentials: credentials, maintenance: maintenance, photos: photos, development: development, runtime: runtime}, nil
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
	return e.inspect(r, false)
}

// InspectDevelopment is only selected by the server for an authenticated LAN
// engineer. Project documents contain expressions, SQL procedure names and image
// bytes; their schemas are checked by their owning services, not shell heuristics.
// URI/query/header CRS inspection and bounded request buffering remain enabled.
func (e *Engine) InspectDevelopment(r *http.Request) ([]byte, string) {
	return e.inspect(r, true)
}

func (e *Engine) inspect(r *http.Request, development bool) (owned []byte, decision string) {
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
	photo := r.Method == "POST" && r.URL.EscapedPath() == r.URL.Path && photoPost.MatchString(r.URL.Path)
	// Binary protobuf is validated by the generated RPC decoder and selector
	// schema. Keep URI/header inspection, rate limits and bounded input; never
	// feed arbitrary binary into text injection heuristics or broaden other APIs.
	runtime := r.Method == "POST" && r.URL.EscapedPath() == runtimewire.SubscribeProcedure &&
		(r.Header.Get("Content-Type") == "application/grpc-web+proto" || r.Header.Get("Content-Type") == "application/grpc+proto" || r.Header.Get("Content-Type") == "application/grpc")
	limit := 65536
	if photo {
		limit = 3 * 1024 * 1024
	}
	if development {
		limit = 32 * 1024 * 1024
	}
	if runtime {
		limit = 1024 * 1024
	}
	if r.Body != nil {
		defer r.Body.Close()
		var err error
		owned, err = io.ReadAll(io.LimitReader(r.Body, int64(limit+1)))
		if err != nil {
			return nil, "body_read_error"
		}
		if len(owned) > limit {
			return nil, "body_limit"
		}
	}
	waf := e.baseline
	if photo {
		waf = e.photos
	}
	if maintenanceMethod(r) {
		waf = e.maintenance
	}
	if development {
		waf = e.development
	}
	if runtime {
		waf = e.runtime
	}
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
	if !development && !runtime && reader.Len() != 0 {
		return nil, "uninspected_remainder"
	}
	if interruption, err := tx.ProcessRequestBody(); err != nil {
		return nil, "body_parse_error"
	} else if interruption != nil {
		return nil, "blocked_body"
	}
	return owned, "allowed"
}
