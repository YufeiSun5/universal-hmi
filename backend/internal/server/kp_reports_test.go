package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
)

func TestKPReportEntryThroughPublicBoundary(t *testing.T) {
	bridge, err := kpbridge.New(kpbridge.Options{SourceID: "kp", WorkspaceID: "fixture", Verifier: kpbridge.VerifyFunc(func(context.Context, string, kpbridge.Bootstrap) (kpbridge.Identity, error) {
		return kpbridge.Identity{}, nil
	})})
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for name, body := range map[string]string{"total-reports/index.html": `<script src="./assets/report.js"></script>KP report`, "total-reports/assets/report.js": "window.reportLoaded=true"} {
		file := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(file), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	kp, err := KPHandler(bridge, KPOptions{PublicOrigin: "http://127.0.0.1:18145", KPOrigins: []string{"http://127.0.0.1:11005"}, WebDir: dir, LocalTrial: true}, nil, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	h, err := PublicAccessHandler(http.NotFoundHandler(), PublicAccessOptions{KP: kp, Policy: func(netip.Addr) bool { return false }})
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://127.0.0.1:18145"+path, nil)
		r.RemoteAddr = "192.0.2.10:1234"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for _, entry := range []string{"/kp/total-reports/", "/kp/total-reports/index.html"} {
		for _, method := range []string{"GET", "HEAD"} {
			w := call(method, entry+"?development=false")
			if w.Code != 200 || w.Header().Get("Location") != "" || !strings.Contains(w.Header().Get("Content-Type"), "text/html") {
				t.Fatalf("%s %s: %d %s", method, entry, w.Code, w.Body.String())
			}
			if method == "GET" && !strings.Contains(w.Body.String(), "KP report") || method == "HEAD" && w.Body.Len() != 0 {
				t.Fatal("wrong report response", method, w.Body.String())
			}
			if !strings.Contains(w.Header().Get("Content-Security-Policy"), "http://127.0.0.1:11005") || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("embed/cache policy changed", w.Header())
			}
		}
	}
	if w := call("GET", "/kp/total-reports/assets/report.js"); w.Code != 200 || !strings.Contains(w.Body.String(), "reportLoaded") {
		t.Fatal("relative report asset", w.Code, w.Body.String())
	}
	for _, path := range []string{"/kp/total-reports//", "/kp/total-reports/../", "/kp/total-reports/./", "/kp/total-reports%2f", "/kp/total-reports%5c", "/kp/total-reports/assets/", "/kp/assets/", "/kp/total-reports/api/v1/points", "/api/v1/total-reports/heat/2026/history-state"} {
		if w := call("GET", path); w.Code < 400 {
			t.Fatal("noncanonical/directory/anonymous API reached", path, w.Code)
		}
	}
	if w := call("POST", "/kp/total-reports/"); w.Code != 403 {
		t.Fatal("report entry accepted mutation", w.Code)
	}
	if err := os.Remove(filepath.Join(dir, "total-reports", "index.html")); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", "/kp/total-reports/"); w.Code != 404 || strings.Contains(w.Body.String(), "report.js") {
		t.Fatal("missing index exposed directory", w.Code, w.Body.String())
	}
}
