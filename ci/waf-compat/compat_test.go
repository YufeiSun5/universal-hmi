package wafcompat

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	corazaconf "github.com/corazawaf/coraza-coreruleset/coraza/v3"
	crs "github.com/corazawaf/coraza-coreruleset/crs/v4"
	"github.com/corazawaf/coraza/v3"
	"github.com/jcchavezs/mergefs"
)

// This test-only connector characterizes the candidate; it is not imported by
// the backend and does not establish production route or session protection.
func candidate(t *testing.T) coraza.WAF {
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
Include @crs-setup.conf.example
Include @owasp_crs/*.conf
`))
	if err != nil {
		t.Fatal(err)
	}
	return waf
}

// Only fixed outcomes leave this harness. No matched data or engine error text
// is logged. Body ownership is independent of transaction lifetime.
func inspect(waf coraza.WAF, r *http.Request) (body []byte, decision string) {
	tx := waf.NewTransaction()
	defer tx.Close()
	tx.ProcessConnection("192.0.2.10", 12345, "192.0.2.20", 443)
	tx.ProcessURI(r.URL.RequestURI(), r.Method, r.Proto)
	tx.AddRequestHeader("Host", r.Host)
	tx.SetServerName(r.Host)
	for k, values := range r.Header {
		for _, v := range values {
			tx.AddRequestHeader(k, v)
		}
	}
	if tx.ProcessRequestHeaders() != nil {
		return nil, "blocked_headers"
	}
	if r.Body != nil {
		data, err := io.ReadAll(io.LimitReader(r.Body, 65537))
		if err != nil {
			return nil, "body_read_error"
		}
		if len(data) > 65536 {
			return nil, "body_limit"
		}
		if interruption, _, err := tx.ReadRequestBodyFrom(bytes.NewReader(data)); err != nil {
			return nil, "body_parse_error"
		} else if interruption != nil {
			return nil, "blocked_body"
		}
		body = data
	}
	if interruption, err := tx.ProcessRequestBody(); err != nil {
		return nil, "body_parse_error"
	} else if interruption != nil {
		return nil, "blocked_body"
	}
	return body, "allowed"
}

func request(method, target, body string) *http.Request {
	r := httptest.NewRequest(method, "https://hmi.example"+target, strings.NewReader(body))
	r.Header.Set("User-Agent", "HMI-compatibility-test")
	r.Header.Set("Accept", "application/json")
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	return r
}

func TestCandidateNormalAndAttackRequests(t *testing.T) {
	waf := candidate(t)
	for _, tc := range []struct {
		name, method, target, body string
		allowed                    bool
	}{
		{"read", "GET", "/api/v1/stations", "", true},
		{"login", "POST", "/api/v1/auth/login", `{"username":"operator","password":"a long ordinary password 123"}`, true},
		{"chinese_query", "POST", "/api/v1/external/screens/example/query", `{"station":"中文站点","from":"2026-10-01","to":"2026-10-02"}`, true},
		{"sql_in_query", "GET", "/api/v1/stations?name=1%27%20OR%201%3D1--", "", false},
		{"xss_in_body", "POST", "/api/v1/auth/login", `{"username":"<script>alert(1)</script>","password":"ordinary password"}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, outcome := inspect(waf, request(tc.method, tc.target, tc.body))
			if (outcome == "allowed") != tc.allowed {
				t.Fatalf("unexpected fixed decision: %s", outcome)
			}
			if tc.allowed && string(body) != tc.body {
				t.Fatal("inspected body changed")
			}
		})
	}
}

func TestCandidateRejectsOversizedRequest(t *testing.T) {
	_, outcome := inspect(candidate(t), request("POST", "/api/v1/auth/login", strings.Repeat("x", 65537)))
	if outcome == "allowed" {
		t.Fatal("oversized input was allowed")
	}
}

// This is deliberately characterization, not an assertion that login is ready
// for production. Opaque passwords must remain arbitrary application data.
func TestCandidateOpaquePasswordCharacterization(t *testing.T) {
	waf := candidate(t)
	for _, tc := range []struct{ name, body string }{
		{"quoted", `{"username":"operator","password":"this is O'Reilly's long password"}`},
		{"sql_like", `{"username":"operator","password":"' OR 1=1; SELECT password FROM users --"}`},
		{"script_like", `{"username":"operator","password":"<script>alert(1)</script>"}`},
		{"php_like", `{"username":"operator","password":"<?php system('id'); ?>"}`},
	} {
		_, outcome := inspect(waf, request("POST", "/api/v1/auth/login", tc.body))
		t.Logf("synthetic opaque password case=%s fixed_decision=%s", tc.name, outcome)
	}
}

func TestCandidateParserLimits(t *testing.T) {
	waf := candidate(t)
	t.Run("deep_json", func(t *testing.T) {
		body := strings.Repeat(`{"a":`, 1200) + `0` + strings.Repeat(`}`, 1200)
		if _, decision := inspect(waf, request("POST", "/api/v1/external/screens/example/query", body)); decision == "allowed" {
			t.Fatal("deep JSON accepted")
		}
	})
	t.Run("argument_tail", func(t *testing.T) {
		var body strings.Builder
		body.WriteString(`{`)
		for i := 0; i < 1100; i++ {
			fmt.Fprintf(&body, `"p%d":"ok",`, i)
		}
		body.WriteString(`"tail":"<script>alert(1)</script>"}`)
		benign := strings.Replace(body.String(), "<script>alert(1)</script>", "ok", 1)
		if _, decision := inspect(waf, request("POST", "/api/v1/external/screens/example/query", benign)); decision == "allowed" {
			t.Fatal("benign argument overflow accepted")
		}
		if _, decision := inspect(waf, request("POST", "/api/v1/external/screens/example/query", body.String())); decision == "allowed" {
			t.Fatal("argument overflow or attack tail accepted")
		}
	})
}
