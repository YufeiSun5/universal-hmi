package server

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestPublicAssetsRevalidateWithoutCachingIdentityOrAdmissionFailures(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"main.dart.js", "index.html", "hmi_start.js", "flutter_bootstrap.js"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("build one"), 0600); err != nil {
			t.Fatal(err)
		}
		old := time.Now().Add(-time.Hour)
		if err := os.Chtimes(filepath.Join(dir, name), old, old); err != nil {
			t.Fatal(err)
		}
	}
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	allowed := true
	options := IdentityOptions{Origin: "https://example.test", PublicReadOnly: true}
	static, err := IdentityHandler(ids, options, RevalidatingWebAssets(http.FileServer(http.Dir(dir))))
	if err != nil {
		t.Fatal(err)
	}
	handler, err := PublicAccessHandler(static, PublicAccessOptions{Policy: func(_ netip.Addr) bool { return allowed }, Static: static})
	if err != nil {
		t.Fatal(err)
	}
	call := func(path, since string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "https://example.test"+path, nil)
		r.RemoteAddr = "127.0.0.1:1234"
		r.TLS = &tls.ConnectionState{HandshakeComplete: true}
		if since != "" {
			r.Header.Set("If-Modified-Since", since)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	first := call("/main.dart.js", "")
	if first.Code != 200 || first.Header().Get("Cache-Control") != "private, no-cache" {
		t.Fatal(first.Code, first.Header())
	}
	since := first.Header().Get("Last-Modified")
	if since == "" {
		t.Fatal("missing validator")
	}
	if w := call("/main.dart.js", since); w.Code != 304 || w.Body.Len() != 0 {
		t.Fatal("not revalidated", w.Code)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.dart.js"), []byte("new build"), 0600); err != nil {
		t.Fatal(err)
	}
	if w := call("/main.dart.js", since); w.Code != 200 || w.Body.String() != "new build" {
		t.Fatal("stale build", w.Code)
	}
	for _, path := range []string{"/", "/hmi_start.js", "/flutter_bootstrap.js", "/api/v1/auth/session", "/api/v1/points"} {
		if w := call(path, ""); w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal(path, w.Header())
		}
	}
	allowed = false
	if w := call("/main.dart.js", since); w.Code != 403 || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("cached resource bypassed revoked IP", w.Code, w.Header())
	}
}
