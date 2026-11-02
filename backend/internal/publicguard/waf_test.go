package publicguard

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPinnedWAFRequestsAndOpaquePasswords(t *testing.T) {
	engine, err := New()
	if err != nil {
		t.Fatal(err)
	}
	for _, password := range []string{"中文复杂密码 O'Reilly <>&", "' OR 1=1; SELECT password FROM users --", "<script>alert(1)</script>", "${jndi:ldap://synthetic.invalid/a}"} {
		data, _ := json.Marshal(map[string]any{"username": "中文用户", "password": password, "issue_token": false, "captcha_id": "0123456789abcdef0123456789abcdef0123456789abcdef", "captcha_answer": "12345"})
		r := httptest.NewRequest("POST", "https://192.0.2.1/api/v1/auth/login", bytes.NewReader(data))
		r.Header.Set("User-Agent", "HMI-test")
		r.Header.Set("Accept", "application/json")
		r.Header.Set("Content-Type", "application/json")
		body, decision := engine.Inspect(r)
		if decision != "allowed" || !bytes.Equal(body, data) {
			t.Fatal("opaque password rejected or changed", decision)
		}
	}
	for _, test := range []struct{ path, body string }{
		{"/api/v1/external/screens/a/query", `{"station":"中文站区","from":"2026-10-01","to":"2026-10-02"}`},
		{"/api/v1/points?search=%E4%B8%AD%E6%96%87", ""},
	} {
		r := httptest.NewRequest("GET", "https://192.0.2.1"+test.path, strings.NewReader(test.body))
		r.Header.Set("User-Agent", "HMI-test")
		r.Header.Set("Accept", "application/json")
		if test.body != "" {
			r.Method = "POST"
			r.Header.Set("Content-Type", "application/json")
		}
		if _, decision := engine.Inspect(r); decision != "allowed" {
			t.Fatal("legitimate request rejected", decision)
		}
	}
	for _, test := range []struct{ path, body string }{
		{"/api/v1/points?q=%27%20OR%201%3D1%20--", ""},
		{"/api/v1/points?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E", ""},
		{"/api/v1/auth/login", `{"username":"x","password":"x","password":"y"}`},
		{"/api/v1/auth/login", `{"username":"x","Password":"x"}`},
		{"/api/v1/auth/login?password=alias", `{"username":"x","password":"x"}`},
		{"/api/v1/external/screens/a/query", strings.Repeat("[", 1100) + "0" + strings.Repeat("]", 1100)},
		{"/api/v1/external/screens/a/query", strings.Repeat("x", 65537)},
	} {
		r := httptest.NewRequest("GET", "https://192.0.2.1"+test.path, strings.NewReader(test.body))
		r.Header.Set("User-Agent", "HMI-test")
		r.Header.Set("Accept", "application/json")
		if test.body != "" {
			r.Method = "POST"
			r.Header.Set("Content-Type", "application/json")
		}
		if _, decision := engine.Inspect(r); decision == "allowed" {
			t.Fatal("attack accepted", test.path)
		}
	}
}
