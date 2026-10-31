package server

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestIdentityRejectDrainsOnlyBoundedBody(t *testing.T) {
	body := strings.Repeat("x", 128*1024)
	r := httptest.NewRequest("POST", "https://example.invalid/", strings.NewReader(body))
	w := httptest.NewRecorder()
	identityReject(w, r, 403, "test", "rejected")
	remaining, _ := io.ReadAll(r.Body)
	if len(remaining) != 64*1024 || w.Code != 403 || w.Header().Get("Connection") != "close" {
		t.Fatalf("unbounded drain or response: remaining=%d status=%d", len(remaining), w.Code)
	}
}
func TestIdentityTLSConnectionCloseRejectedBody(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	srv := httptest.NewUnstartedServer(nil)
	origin := "https://" + srv.Listener.Addr().String()
	h, e := IdentityHandler(ids, IdentityOptions{Origin: origin}, http.NotFoundHandler())
	if e != nil {
		t.Fatal(e)
	}
	srv.Config.Handler = h
	srv.StartTLS()
	defer srv.Close()
	for i := 0; i < 25; i++ {
		req, _ := http.NewRequest("PUT", origin+"/api/v1/screens/rejected", strings.NewReader(strings.Repeat("x", 1024)))
		req.Close = true
		req.Header.Set("Origin", origin)
		expected := 401
		if i%2 == 1 {
			req.Header.Set("Origin", "https://wrong.invalid")
			expected = 403
		}
		response, e := srv.Client().Do(req)
		if e != nil {
			t.Fatalf("iteration %d disconnected: %v", i, e)
		}
		data, e := io.ReadAll(response.Body)
		response.Body.Close()
		if e != nil || response.StatusCode != expected || len(data) == 0 {
			t.Fatalf("iteration %d status=%d read=%v", i, response.StatusCode, e)
		}
	}
}

func TestIdentityTLSIncompleteRejectedBodyIsBounded(t *testing.T) {
	ids, e := identity.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer ids.Close()
	srv := httptest.NewUnstartedServer(nil)
	origin := "https://" + srv.Listener.Addr().String()
	handler, e := IdentityHandler(ids, IdentityOptions{Origin: origin}, http.NotFoundHandler())
	if e != nil {
		t.Fatal(e)
	}
	srv.Config.Handler = handler
	srv.StartTLS()
	defer srv.Close()
	for _, declared := range []int{1024, 128 * 1024} {
		conn, e := tls.Dial("tcp", srv.Listener.Addr().String(), &tls.Config{InsecureSkipVerify: true})
		if e != nil {
			t.Fatal(e)
		}
		conn.SetDeadline(time.Now().Add(4 * time.Second))
		started := time.Now()
		fmt.Fprintf(conn, "PUT /api/v1/screens/rejected HTTP/1.1\r\nHost: %s\r\nOrigin: https://wrong.invalid\r\nContent-Length: %d\r\n\r\nx", srv.Listener.Addr(), declared)
		response, e := http.ReadResponse(bufio.NewReader(conn), nil)
		if e != nil {
			conn.Close()
			t.Fatalf("incomplete %d body lost rejection: %v", declared, e)
		}
		_, e = io.ReadAll(response.Body)
		response.Body.Close()
		conn.Close()
		if e != nil || response.StatusCode != 403 || time.Since(started) > 3*time.Second {
			t.Fatalf("incomplete %d body exceeded bound: status=%d read=%v elapsed=%s", declared, response.StatusCode, e, time.Since(started))
		}
	}
}
