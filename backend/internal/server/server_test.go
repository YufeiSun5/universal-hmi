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
