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
	// Old clients still send this redundant same-origin field. Compatibility is
	// restricted to this exact entry, scheme and host; other input is inspected.
	r := httptest.NewRequest("GET", "http://192.168.1.20:18080/total-reports/?parentOrigin=http%3A%2F%2F192.168.1.20%3A18080&development=true", nil)
	r.Header.Set("User-Agent", "Mozilla/5.0")
	if _, decision := e.Inspect(r); decision != "allowed" {
		t.Fatal("same-origin legacy report rejected", decision)
	}
	for _, target := range []string{
		"/kp/total-reports/?parentOrigin=http%3A%2F%2F192.168.1.20%3A18080&development=false",
		"/kp/total-reports/index.html?parentOrigin=http%3A%2F%2F192.168.1.20%3A18080&development=false",
		"/total-reports/index.html?parentOrigin=http%3A%2F%2F192.168.1.20%3A18080&development=false",
		"/total-reports/?parentOrigin=http%3A%2F%2F192.168.1.20%3A18080&development=true",
	} {
		r := httptest.NewRequest("GET", "http://192.168.1.20:18080"+target, nil)
		r.Header.Set("User-Agent", "Mozilla/5.0")
		if _, decision := e.Inspect(r); decision != "allowed" {
			t.Fatal(target, decision)
		}
	}
	for _, target := range []string{
		"/kp/total-reports/?parentOrigin=http://192.168.1.21:18080",
		"/kp/total-reports/?parentOrigin=http://192.168.1.20:18080&x=%27%20OR%201%3D1%20--",
		"/kp/total-reports/?parentOrigin=http://192.168.1.20:18080&parentOrigin=http://192.168.1.21:18080",
		"/total-reports/?parentOrigin=http://192.168.1.21:18080",
		"/api/v1/points?parentOrigin=http://192.168.1.20:18080",
		"/total-reports/?parentOrigin=http://192.168.1.20:18080&x=%27%20OR%201%3D1%20--",
		"/total-reports/?parentOrigin=http://192.168.1.20:18080&parentOrigin=http://192.168.1.21:18080",
	} {
		r := httptest.NewRequest("GET", "http://192.168.1.20:18080"+target, nil)
		r.Header.Set("User-Agent", "Mozilla/5.0")
		_, decision, rules := e.InspectDetailed(r, false)
		if decision == "allowed" || len(rules) == 0 {
			t.Fatal("hostile/foreign query not diagnosed", target, decision, rules)
		}
	}
}
