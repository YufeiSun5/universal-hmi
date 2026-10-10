package kpbridge

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTrustedVerifierContractAndFailureBoundaries(t *testing.T) {
	for _, mode := range []string{"valid", "wrong-binding", "unverified", "denied", "unavailable", "redirect", "malformed", "trailing", "oversized"} {
		t.Run(mode, func(t *testing.T) {
			srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var b struct {
					SourceID string `json:"sourceId"`
					Bootstrap
				}
				if r.Method != "POST" || json.NewDecoder(r.Body).Decode(&b) != nil || b.IdentityProof != "proof" {
					t.Error("invalid verification request")
				}
				switch mode {
				case "denied":
					w.WriteHeader(401)
					return
				case "unavailable":
					w.WriteHeader(500)
					return
				case "redirect":
					w.Header().Set("Location", "https://elsewhere.invalid")
					w.WriteHeader(302)
					return
				case "malformed":
					_, _ = w.Write([]byte("oops"))
					return
				}
				v := map[string]any{"verified": mode != "unverified", "sourceId": b.SourceID, "contextId": b.ContextID, "loginVersion": b.LoginVersion, "subject": "stable-a", "userName": b.UserName}
				if mode == "wrong-binding" {
					v["loginVersion"] = "other"
				}
				_ = json.NewEncoder(w).Encode(v)
				if mode == "trailing" {
					_, _ = w.Write([]byte("{}"))
				}
				if mode == "oversized" {
					_, _ = w.Write([]byte(strings.Repeat(" ", 32*1024) + "{}"))
				}
			}))
			defer srv.Close()
			v, e := NewHTTPVerifier(srv.URL, srv.Client().Transport)
			if e != nil {
				t.Fatal(e)
			}
			id, e := v.Verify(context.Background(), "kp", Bootstrap{"tab", "v", "A", "kp", "proof"})
			if mode == "valid" {
				if e != nil || id.Subject != "stable-a" {
					t.Fatal(id, e)
				}
			} else if e == nil {
				t.Fatal("accepted invalid verification")
			}
			_, e = v.Verify(context.Background(), "kp", Bootstrap{"tab", "v", "A", "kp", ""})
			code(t, e, "identity_proof_required")
		})
	}
	for _, u := range []string{"http://localhost/verify", "https://user:pass@example/verify", "https://example/verify?q=1", "https://example/verify#x"} {
		if _, e := NewHTTPVerifier(u, nil); e == nil {
			t.Fatalf("accepted %s", u)
		}
	}
}
