package publicguard

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDevelopmentRequestContract(t *testing.T) {
	e, err := New()
	if err != nil {
		t.Fatal(err)
	}
	body := `{"station":"A","name":"LAN point","source_type":"manual","data_type":"FLOAT"}`
	r := httptest.NewRequest("POST", "https://127.0.0.1:12345/api/v1/points", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("User-Agent", "Go-http-client/1.1")
	r.Header.Set("Origin", "https://127.0.0.1:12345")
	if _, decision := e.InspectDevelopment(r); decision != "allowed" {
		tx := e.development.NewTransaction()
		defer tx.Close()
		tx.ProcessURI(r.URL.RequestURI(), r.Method, r.Proto)
		tx.AddRequestHeader("Host", r.Host)
		for name, vs := range r.Header {
			for _, v := range vs {
				tx.AddRequestHeader(name, v)
			}
		}
		tx.ProcessRequestHeaders()
		tx.ReadRequestBodyFrom(strings.NewReader(body))
		tx.ProcessRequestBody()
		for _, m := range tx.MatchedRules() {
			if m.Message() != "" {
				t.Log(m.ErrorLog())
			}
		}
		t.Fatal(decision)
	}
}
