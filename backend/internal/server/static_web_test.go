package server

import (
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func TestCompressedWebFiles(t *testing.T) {
	dir := t.TempDir()
	original := bytes.Repeat([]byte("wasm test bytes"), 200)
	name := filepath.Join(dir, "main.dart.wasm")
	if err := os.WriteFile(name, original, 0600); err != nil {
		t.Fatal(err)
	}
	var packed bytes.Buffer
	gz := gzip.NewWriter(&packed)
	_, _ = gz.Write(original)
	_ = gz.Close()
	if err := os.WriteFile(name+".gz", packed.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	handler := WebFiles(dir)
	call := func(encoding, method, since, span string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/main.dart.wasm", nil)
		r.Header.Set("Accept-Encoding", encoding)
		r.Header.Set("If-Modified-Since", since)
		r.Header.Set("Range", span)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	first := call("br, gzip", "GET", "", "")
	if first.Code != 200 || first.Header().Get("Content-Encoding") != "gzip" || first.Header().Get("Content-Type") != "application/wasm" || first.Header().Get("Vary") != "Accept-Encoding" {
		t.Fatal(first.Code, first.Header())
	}
	reader, err := gzip.NewReader(first.Body)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := io.ReadAll(reader)
	_ = reader.Close()
	if err != nil || !bytes.Equal(decoded, original) {
		t.Fatal("corrupt compressed content")
	}
	for _, encoding := range []string{"", "gzip;q=0", "gzip;q=bad", "gzip;q=NaN", "br"} {
		w := call(encoding, "GET", "", "")
		if w.Header().Get("Content-Encoding") != "" || !bytes.Equal(w.Body.Bytes(), original) {
			t.Fatal("encoding negotiation", encoding)
		}
	}
	if w := call("gzip", "HEAD", "", ""); w.Code != 200 || w.Body.Len() != 0 || w.Header().Get("Content-Encoding") != "gzip" {
		t.Fatal("HEAD", w.Code, w.Header())
	}
	if w := call("gzip", "GET", first.Header().Get("Last-Modified"), ""); w.Code != 304 || w.Body.Len() != 0 {
		t.Fatal("conditional", w.Code)
	}
	if w := call("gzip", "GET", "", "bytes=0-4"); w.Code != 206 || w.Header().Get("Content-Encoding") != "" || w.Body.Len() != 5 {
		t.Fatal("range", w.Code, w.Header())
	}
	future := time.Now().Add(time.Hour)
	if err := os.Chtimes(name, future, future); err != nil {
		t.Fatal(err)
	}
	if w := call("gzip", "GET", "", ""); w.Header().Get("Content-Encoding") != "" || !bytes.Equal(w.Body.Bytes(), original) {
		t.Fatal("stale gzip served")
	}
}

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
