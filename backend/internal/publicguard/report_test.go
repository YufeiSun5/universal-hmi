package publicguard

import (
	"net/http/httptest"
	"testing"
)

func TestReportEmbeddingDoesNotNeedOriginQuery(t *testing.T) {
	e, err := New()
	if err != nil {
		t.Fatal(err)
	}
	for _, origin := range []string{"http://192.168.1.20:18080", "https://192.168.1.20:18443"} {
		for _, suffix := range []string{"?development=true", "?development=false", "assets/index.js"} {
			r := httptest.NewRequest("GET", origin+"/total-reports/"+suffix, nil)
			r.Header.Set("User-Agent", "Mozilla/5.0")
			r.Header.Set("Referer", origin+"/?mode=development")
			if _, decision := e.Inspect(r); decision != "allowed" {
				t.Fatalf("%s: %s", suffix, decision)
			}
		}
	}
	// The old embedded URL is interpreted as a remote-file inclusion attempt by
	// CRS. Remove the unused parameter in the client, never exempt URI inspection.
	r := httptest.NewRequest("GET", "http://192.168.1.20:18080/total-reports/?parentOrigin=http%3A%2F%2F192.168.1.20%3A18080&development=true", nil)
	r.Header.Set("User-Agent", "Mozilla/5.0")
	if _, decision := e.Inspect(r); decision == "allowed" {
		t.Fatal("old URI no longer reproduces the reported WAF rejection")
	}
}
