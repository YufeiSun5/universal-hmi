package wafcompat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"

	corazaconf "github.com/corazawaf/coraza-coreruleset/coraza/v3"
	crs "github.com/corazawaf/coraza-coreruleset/crs/v4"
	"github.com/corazawaf/coraza/v3"
	"github.com/corazawaf/coraza/v3/types"
	"github.com/jcchavezs/mergefs"
)

// Only this exact target is opaque; ARGS_NAMES, query, username, code, protocol,
// body parsing and limits remain inspected. See official Coraza ctl action docs.
const passwordTargetControl = `
SecRule REQUEST_METHOD "@streq POST" "id:10001,phase:1,pass,nolog,chain"
 SecRule REQUEST_FILENAME "@rx ^/api/v1/(auth/login|security/mfa/begin)$" "t:none,chain"
 SecRule REQUEST_HEADERS:Content-Type "@streq application/json" "t:none,ctl:ruleRemoveTargetByTag=OWASP_CRS;ARGS:json.password"
`

func tunedCandidate(t *testing.T) coraza.WAF {
	t.Helper()
	waf, err := coraza.NewWAF(coraza.NewWAFConfig().WithRootFS(mergefs.Merge(corazaconf.FS, crs.FS)).WithDirectives(`
Include @coraza.conf-recommended
SecRuleEngine On
SecAuditEngine Off
SecDebugLogLevel 0
SecRequestBodyLimit 65536
SecRequestBodyNoFilesLimit 65536
SecRequestBodyInMemoryLimit 65536
SecRequestBodyLimitAction Reject
SecResponseBodyAccess Off
` + passwordTargetControl + `
Include @crs-setup.conf.example
Include @owasp_crs/*.conf
`))
	if err != nil {
		t.Fatal("candidate rule construction failed")
	}
	return waf
}

// Strict schema validation is an exception eligibility check, not authentication.
// Reject ambiguous auth JSON rather than letting parser/key normalization select
// a different password from the application. No input fragments leave this helper.
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
		case "password":
			var v string
			if len(value) == 0 || value[0] != '"' || json.Unmarshal(value, &v) != nil {
				return false
			}
		case "username", "code":
			if !login {
				return false
			}
			var v string
			if len(value) == 0 || value[0] != '"' || json.Unmarshal(value, &v) != nil {
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
	if err != nil || token != json.Delim('}') || d.Decode(new(any)) != io.EOF {
		return false
	}
	return seen["password"] && (!login || seen["username"])
}

type requestConnector struct {
	baseline, tuned coraza.WAF
	// Test-only observer/fault injection forwards to real Coraza transactions.
	wrap func(types.Transaction) types.Transaction
}

func newRequestConnector(t *testing.T) *requestConnector {
	return &requestConnector{baseline: candidate(t), tuned: tunedCandidate(t)}
}
func (c *requestConnector) inspectRequest(r *http.Request) (owned []byte, decision string) {
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
	waf := c.baseline
	exactPath := r.URL.EscapedPath() == r.URL.Path && (r.URL.Path == "/api/v1/auth/login" || r.URL.Path == "/api/v1/security/mfa/begin")
	if r.Method == "POST" && exactPath && len(r.Header.Values("Content-Type")) == 1 && r.Header.Get("Content-Type") == "application/json" {
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
		waf = c.tuned
	}
	tx := waf.NewTransaction()
	if c.wrap != nil {
		tx = c.wrap(tx)
	}
	defer func() {
		if tx.Close() != nil {
			owned = nil
			decision = "transaction_close_error"
		}
	}()
	tx.ProcessConnection("192.0.2.10", 12345, "192.0.2.20", 443)
	tx.ProcessURI(r.URL.RequestURI(), r.Method, r.Proto)
	tx.SetServerName(r.Host)
	tx.AddRequestHeader("Host", r.Host)
	for key, values := range r.Header {
		for _, value := range values {
			tx.AddRequestHeader(key, value)
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
func (c *requestConnector) handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, decision := c.inspectRequest(r)
		if decision != "allowed" {
			status := 403
			if decision == "body_limit" {
				status = 413
			}
			http.Error(w, decision, status)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		next.ServeHTTP(w, r)
	})
}

type observedTx struct {
	types.Transaction
	closed     *atomic.Int32
	closeError error
}

func (t *observedTx) Close() error {
	err := t.Transaction.Close()
	t.closed.Add(1)
	if t.closeError != nil {
		return t.closeError
	}
	return err
}

type prefixOnlyTx struct{ types.Transaction }

func (t prefixOnlyTx) ReadRequestBodyFrom(r io.Reader) (*types.Interruption, int, error) {
	return t.Transaction.ReadRequestBodyFrom(io.LimitReader(r, 2))
}

func TestTunedOpaquePasswordAndExactReplay(t *testing.T) {
	c := newRequestConnector(t)
	for _, path := range []string{"/api/v1/auth/login", "/api/v1/security/mfa/begin"} {
		for _, password := range []string{"O'Reilly's password <>&", "' OR 1=1; SELECT password FROM users --", "<script>alert(1)</script>", "<?php system('id'); ?>", "${jndi:ldap://synthetic.invalid/a}", "{{7*7}} /bin/bash", "中文口令\tnewline\n"} {
			fields := map[string]any{"password": password}
			if path == "/api/v1/auth/login" {
				fields["username"] = "中文操作员"
				fields["issue_token"] = false
				fields["code"] = "123456"
			}
			data, _ := json.MarshalIndent(fields, "", "  ")
			data = append([]byte(" \n"), append(data, '\n')...)
			var closed atomic.Int32
			c.wrap = func(tx types.Transaction) types.Transaction { return &observedTx{Transaction: tx, closed: &closed} }
			called := false
			handler := c.handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				called = true
				if closed.Load() != 1 {
					t.Error("transaction live downstream")
				}
				got, _ := io.ReadAll(r.Body)
				if !bytes.Equal(got, data) {
					t.Error("body replay changed bytes")
				}
				w.Write([]byte("unchanged response"))
			}))
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, request("POST", path, string(data)))
			if !called || w.Code != 200 || w.Body.String() != "unchanged response" {
				t.Fatalf("opaque credential rejected: path=%s decision=%s", path, w.Body.String())
			}
		}
	}
}
func TestTunedExceptionBoundary(t *testing.T) {
	c := newRequestConnector(t)
	attack := `<script>alert(1)</script>`
	for _, tc := range []struct{ name, method, path, body, ctype string }{
		{"username", "POST", "/api/v1/auth/login", `{"username":"` + attack + `","password":"normal"}`, "application/json"},
		{"code", "POST", "/api/v1/auth/login", `{"username":"normal","password":"normal","code":"` + attack + `"}`, "application/json"},
		{"duplicate", "POST", "/api/v1/auth/login", `{"username":"normal","password":"normal","password":"` + attack + `"}`, "application/json"},
		{"case_alias", "POST", "/api/v1/auth/login", `{"username":"normal","Password":"` + attack + `"}`, "application/json"},
		{"unknown", "POST", "/api/v1/auth/login", `{"username":"normal","password":"normal","extra":"` + attack + `"}`, "application/json"},
		{"nested", "POST", "/api/v1/auth/login", `{"username":"normal","password":{"value":"` + attack + `"}}`, "application/json"},
		{"trailing", "POST", "/api/v1/auth/login", `{"username":"normal","password":"normal"} {}`, "application/json"},
		{"malformed", "POST", "/api/v1/auth/login", "{\"username\":\"normal\",\"password\":\"bad\ncontrol\"}", "application/json"},
		{"query", "POST", "/api/v1/auth/login?name=%3Cscript%3Ealert(1)%3C/script%3E", `{"username":"normal","password":"normal"}`, "application/json"},
		{"query_alias", "POST", "/api/v1/auth/login?json.password=%3Cscript%3Ealert(1)%3C/script%3E", `{"username":"normal","password":"normal"}`, "application/json"},
		{"password_query", "POST", "/api/v1/auth/login?Password=normal", `{"username":"normal","password":"normal"}`, "application/json"},
		{"confirm", "POST", "/api/v1/security/mfa/confirm", `{"password":"` + attack + `"}`, "application/json"},
		{"wrong_method", "PUT", "/api/v1/auth/login", `{"username":"normal","password":"` + attack + `"}`, "application/json"},
		{"other_route", "POST", "/api/v1/external/screens/example/query", `{"password":"` + attack + `"}`, "application/json"},
		{"form", "POST", "/api/v1/auth/login", "json.password=" + url.QueryEscape(attack), "application/x-www-form-urlencoded"},
		{"text", "POST", "/api/v1/auth/login", `{"username":"normal","password":"` + attack + `"}`, "text/plain"},
		{"charset", "POST", "/api/v1/auth/login", `{"username":"normal","password":"` + attack + `"}`, "application/json; charset=utf-8"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := request(tc.method, tc.path, tc.body)
			r.Header.Set("Content-Type", tc.ctype)
			if _, decision := c.inspectRequest(r); decision == "allowed" {
				t.Fatal("out-of-scope attack accepted")
			}
		})
	}
}

func TestTunedParserLimitsAndFullConsumption(t *testing.T) {
	c := newRequestConnector(t)
	for _, body := range []string{strings.Repeat("x", 65537), strings.Repeat(`{"a":`, 1200) + `0` + strings.Repeat(`}`, 1200)} {
		if _, decision := c.inspectRequest(request("POST", "/api/v1/auth/login", body)); decision == "allowed" {
			t.Fatal("body/depth limit accepted")
		}
	}
	// Parameter overflow is denied even when all values are benign.
	var body strings.Builder
	body.WriteString(`{`)
	for i := 0; i < 1100; i++ {
		fmt.Fprintf(&body, `"p%d":"ok",`, i)
	}
	body.WriteString(`"tail":"ok"}`)
	for _, input := range []string{body.String(), strings.Replace(body.String(), `"tail":"ok"`, `"tail":"<script>alert(1)</script>"`, 1)} {
		if _, decision := c.inspectRequest(request("POST", "/api/v1/external/screens/example/query", input)); decision == "allowed" {
			t.Fatal("argument overflow accepted")
		}
	}
	c.wrap = func(tx types.Transaction) types.Transaction { return prefixOnlyTx{tx} }
	if _, decision := c.inspectRequest(request("POST", "/api/v1/external/screens/example/query", `{}<script>alert(1)</script>`)); decision != "uninspected_remainder" {
		t.Fatalf("partial inspection not rejected: %s", decision)
	}
}
func TestTunedCloseFailureNeverReachesDownstream(t *testing.T) {
	c := newRequestConnector(t)
	var closed atomic.Int32
	c.wrap = func(tx types.Transaction) types.Transaction {
		return &observedTx{Transaction: tx, closed: &closed, closeError: errors.New("synthetic secret detail")}
	}
	called := false
	w := httptest.NewRecorder()
	c.handler(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true })).ServeHTTP(w, request("GET", "/api/v1/stations", ""))
	if called || closed.Load() != 1 || strings.TrimSpace(w.Body.String()) != "transaction_close_error" {
		t.Fatal("close failure unsafe response")
	}
}
func TestTunedSSEFlushAfterRealTransactionClose(t *testing.T) {
	c := newRequestConnector(t)
	var closed atomic.Int32
	c.wrap = func(tx types.Transaction) types.Transaction { return &observedTx{Transaction: tx, closed: &closed} }
	continueStream := make(chan struct{})
	finished := make(chan struct{})
	server := httptest.NewServer(c.handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(finished)
		if closed.Load() != 1 {
			t.Error("real Coraza transaction not closed before SSE")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: first\n\n")
		w.(http.Flusher).Flush()
		select {
		case <-continueStream:
		case <-r.Context().Done():
			return
		}
		io.WriteString(w, "data: <script>response-not-inspected</script>\n\n")
		w.(http.Flusher).Flush()
	})))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", server.URL+"/api/v1/runtime/events", nil)
	req.Header.Set("User-Agent", "HMI-compatibility-test")
	req.Header.Set("Accept", "text/event-stream")
	response, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	reader := bufio.NewReader(response.Body)
	line, err := reader.ReadString('\n')
	if err != nil || line != "data: first\n" {
		t.Fatal("first SSE event not flushed")
	}
	select {
	case <-finished:
		t.Fatal("stream ended before release")
	default:
	}
	close(continueStream)
	remaining, err := io.ReadAll(reader)
	if err != nil || !strings.Contains(string(remaining), "response-not-inspected") {
		t.Fatal("stream response modified")
	}
}

func TestTunedContentTypeAndJSONAliases(t *testing.T) {
	c := newRequestConnector(t)
	for _, contentType := range []string{"application/json; charset=utf-8", "Application/JSON", "application/json;charset=UTF-8", " application/json", "application/json; boundary=x"} {
		r := request("POST", "/api/v1/auth/login", `{"username":"operator","password":"<script>alert(1)</script>"}`)
		r.Header.Set("Content-Type", contentType)
		if _, decision := c.inspectRequest(r); decision == "allowed" {
			t.Fatal("content-type variant received exception")
		}
	}
	for _, data := range []string{
		`{"username":"operator","password":"normal","Password":"<script>alert(1)</script>"}`,
		`{"username":"operator","password":"normal","\u0070assword":"<script>alert(1)</script>"}`,
		`{"username":"operator","password":null}`,
		`{"username":"operator","password":"normal","issue_token":"true"}`,
		`{"username":"operator","password":"normal","code":123456}`,
	} {
		if _, decision := c.inspectRequest(request("POST", "/api/v1/auth/login", data)); decision != "credential_shape_invalid" {
			t.Fatalf("ambiguous credential shape: %s", decision)
		}
	}
	r := request("POST", "/api/v1/auth/login", `{"username":"operator","password":"<script>alert(1)</script>"}`)
	r.Header.Add("Content-Type", "application/json")
	if _, decision := c.inspectRequest(r); decision == "allowed" {
		t.Fatal("duplicate content-type got exception")
	}
	for _, query := range []string{"json%2epassword=normal", "JSON.PASSWORD=normal", "bad=%ZZ"} {
		if _, decision := c.inspectRequest(request("POST", "/api/v1/auth/login?"+query, `{"username":"operator","password":"normal"}`)); decision == "allowed" {
			t.Fatal("query parser ambiguity allowed")
		}
	}
	// Noncanonical media type is not categorically rejected by this connector:
	// an ordinary credential still passes baseline CRS without the opaque exception.
	r = request("POST", "/api/v1/auth/login", `{"username":"operator","password":"ordinary long password"}`)
	r.Header.Set("Content-Type", "application/json; charset=utf-8")
	if _, decision := c.inspectRequest(r); decision != "allowed" {
		t.Fatalf("ordinary charset request: %s", decision)
	}
}

func TestTunedPasswordControlIsNecessaryAndLimitsRemain(t *testing.T) {
	c := newRequestConnector(t)
	for _, password := range []string{"' OR 1=1; SELECT password FROM users --", "<script>alert(1)</script>", "<?php system('id'); ?>"} {
		body, _ := json.Marshal(map[string]string{"username": "operator", "password": password})
		if _, decision := inspect(c.baseline, request("POST", "/api/v1/auth/login", string(body))); decision == "allowed" {
			t.Fatal("baseline characterization changed")
		}
		if _, decision := c.inspectRequest(request("POST", "/api/v1/auth/login", string(body))); decision != "allowed" {
			t.Fatalf("target tuning failed: %s", decision)
		}
	}
	body := `{"username":"operator","password":"ordinary long password"}`
	body += strings.Repeat(" ", 65536-len(body))
	// Characterization: CRS/engine rejects this exact-cap whitespace-padded JSON.
	// The connector byte cap is not a promise to admit every smaller document.
	if _, decision := c.inspectRequest(request("POST", "/api/v1/auth/login", body)); decision != "blocked_body" {
		t.Fatalf("exact body limit characterization: %s", decision)
	}
	if _, decision := c.inspectRequest(request("POST", "/api/v1/auth/login", body+" ")); decision != "body_limit" {
		t.Fatalf("over limit: %s", decision)
	}
	deep := strings.Repeat(`{"a":`, 1200) + `0` + strings.Repeat(`}`, 1200)
	if _, decision := c.inspectRequest(request("POST", "/api/v1/external/screens/example/query", deep)); decision == "allowed" {
		t.Fatal("real parser depth limit bypassed")
	}
}
