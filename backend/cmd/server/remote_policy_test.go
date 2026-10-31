package main

import (
	"bytes"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/server"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestRemotePolicySchemaCompatibility(t *testing.T) {
	for _, tc := range []struct {
		name      string
		schema    int
		enabled   bool
		cidr      string
		wantError string
	}{
		{"legacy disabled", 1, false, "", ""},
		{"legacy enabled needs explicit migration", 1, true, "", "explicitly create a disabled schema 2"},
		{"v2 empty deny all", 2, true, "", ""},
		{"v2 IPv4", 2, true, "192.0.2.0/24", ""},
		{"v2 IPv6", 2, true, "2001:db8::/32", ""},
		{"v2 mapped address", 2, true, "::ffff:192.0.2.1", ""},
		{"invalid prefix", 2, true, "192.0.2.0/33", "web_allowlist"},
		{"disabled invalid draft", 2, false, "not-an-ip", "web_allowlist"},
		{"unknown schema", 3, false, "", "schema must be 2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, path := testRemote(t)
			c.Schema, c.Enabled = tc.schema, tc.enabled
			c.WebAllowlist = nil
			if tc.cidr != "" {
				c.WebAllowlist = []server.PublicIPRule{{CIDR: tc.cidr, Owner: "Synthetic"}}
			}
			raw, err := json.MarshalIndent(c, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			result, err := loadRemote(path)
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("expected %q, got %v", tc.wantError, err)
				}
			} else if err != nil {
				t.Fatal(err)
			} else if tc.enabled && result.TLS == nil {
				t.Fatal("enabled valid schema 2 missing TLS")
			}
			after, readErr := os.ReadFile(path)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if !bytes.Equal(raw, after) {
				t.Fatal("loading configuration rewrote original bytes")
			}
		})
	}
}

func TestRemoteEmptyAllowlistDeniesAll(t *testing.T) {
	c, path := testRemote(t)
	c.WebAllowlist = []server.PublicIPRule{}
	raw, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	deployment, err := loadRemote(path)
	if err != nil {
		t.Fatal(err)
	}
	called := false
	handler, err := server.PublicAccessHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true; w.WriteHeader(204) }), server.PublicAccessOptions{WebAllowlist: deployment.Config.WebAllowlist})
	if err != nil {
		t.Fatal(err)
	}
	for _, peer := range []string{"192.0.2.1:1234", "127.0.0.1:1234", "[2001:db8::1]:1234"} {
		req := httptest.NewRequest("GET", "https://203.0.113.5:18443/health", nil)
		req.RemoteAddr = peer
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		if response.Code != 403 || called {
			t.Fatalf("empty allowlist admitted %s: %d", peer, response.Code)
		}
	}
}
