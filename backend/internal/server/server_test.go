package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func TestPointHTTPWorkflowAndCrossOriginRejection(t *testing.T) {
	s, err := points.Open(filepath.Join(t.TempDir(), "points.json"))
	if err != nil {
		t.Fatal(err)
	}
	h := Handler(s, "", "")
	body := `{"station":"S01","name":"Temperature","data_type":"FLOAT","source_type":"manual","unit":"C"}`
	req := httptest.NewRequest("POST", "/api/v1/points", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	var saved points.Definition
	if err := json.Unmarshal(w.Body.Bytes(), &saved); err != nil || saved.ID == "" {
		t.Fatalf("saved point: %v", err)
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/api/v1/points", nil))
	if !strings.Contains(w.Body.String(), saved.ID) {
		t.Fatal("GET lost saved identity")
	}
	req = httptest.NewRequest("POST", "/api/v1/points", strings.NewReader(body))
	req.Header.Set("Origin", "https://untrusted.example")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 403 || len(s.List()) != 1 {
		t.Fatal("cross-origin write accepted")
	}
	req = httptest.NewRequest("POST", "/api/v1/points", strings.NewReader(body+`{}`))
	w = httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 400 {
		t.Fatal("trailing JSON accepted")
	}
}

func TestHealthDoesNotClaimUnimplementedCapabilities(t *testing.T) {
	s, _ := points.Open(filepath.Join(t.TempDir(), "points.json"))
	w := httptest.NewRecorder()
	Handler(s, "", "").ServeHTTP(w, httptest.NewRequest("GET", "/health", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"acquisition":false`) {
		t.Fatal(w.Body.String())
	}
}

func TestBlankPageWithoutWebBuild(t *testing.T) {
	h := LocalAuthHandler(Handler(nil, "", ""), "")
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(method, "http://127.0.0.1:18139/blank.html", nil))
		assertBlankPage(t, w, method, "")
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "http://127.0.0.1:18139/blank.html", nil))
	if w.Code != http.StatusMethodNotAllowed || w.Header().Get("Allow") != "GET, HEAD" {
		t.Fatalf("unsafe blank page request: %d %v", w.Code, w.Header())
	}
}

func assertBlankPage(t *testing.T, w *httptest.ResponseRecorder, method, frames string) {
	t.Helper()
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "text/html; charset=utf-8" || w.Header().Get("Location") != "" || w.Header().Get("Set-Cookie") != "" {
		t.Fatalf("blank page must load without login or redirect: %d %v %s", w.Code, w.Header(), w.Body)
	}
	policy := w.Header().Get("Content-Security-Policy")
	if w.Header().Get("Cache-Control") != "no-store" || !strings.Contains(policy, "default-src 'none'") || w.Header().Get("X-Frame-Options") != "" {
		t.Fatalf("blank page policy: %v", w.Header())
	}
	if frames == "" {
		if strings.Contains(policy, "frame-ancestors") {
			t.Fatalf("local blank page must support cross-port KP embedding: %v", w.Header())
		}
	} else if !strings.Contains(policy, "frame-ancestors "+frames) {
		t.Fatalf("configured KP embedding origins missing: %v", w.Header())
	}
	if method == http.MethodHead {
		if w.Body.Len() != 0 {
			t.Fatal("HEAD returned a body")
		}
	} else if !strings.Contains(w.Body.String(), "<body></body>") || strings.Contains(w.Body.String(), "<script") || strings.Contains(w.Body.String(), "flutter") {
		t.Fatalf("blank page loaded application content: %s", w.Body)
	}
}

func TestOriginGuardUsesActualTransportScheme(t *testing.T) {
	handler := originGuard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }), "")
	for _, test := range []struct {
		target, origin, forwarded string
		want                      int
	}{
		{"https://hmi.example/api/v1/points", "https://hmi.example", "", 204},
		{"https://hmi.example/api/v1/points", "http://hmi.example", "", 403},
		{"http://hmi.example/api/v1/points", "https://hmi.example", "https", 403},
		{"http://hmi.example/api/v1/points", "http://hmi.example", "", 204},
	} {
		t.Run(test.target+test.origin, func(t *testing.T) {
			req := httptest.NewRequest("POST", test.target, nil)
			req.Header.Set("Origin", test.origin)
			req.Header.Set("X-Forwarded-Proto", test.forwarded)
			out := httptest.NewRecorder()
			handler.ServeHTTP(out, req)
			if out.Code != test.want {
				t.Fatalf("status %d, want %d", out.Code, test.want)
			}
		})
	}
}
