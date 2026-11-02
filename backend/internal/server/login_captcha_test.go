package server

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"image/png"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func seedLoginCaptcha(c *loginCaptchas, binding string) string {
	var random [24]byte
	_, _ = rand.Read(random[:])
	id := hex.EncodeToString(random[:])
	c.mu.Lock()
	c.entries[id] = loginCaptchaEntry{binding: binding, answer: sha256.Sum256([]byte("12345")), expires: c.now().Add(loginCaptchaTTL)}
	c.mu.Unlock()
	return id
}

func TestLoginCaptchaImageBindingExpiryAndSingleUse(t *testing.T) {
	c := newLoginCaptchas()
	now := time.Now()
	c.now = func() time.Time { return now }
	r := httptest.NewRequest("GET", "https://example.invalid"+loginCaptchaPath, nil)
	r.RemoteAddr = "192.0.2.3:1234"
	v, ok := c.issue(r)
	if !ok {
		t.Fatal("issue")
	}
	data, e := base64.StdEncoding.DecodeString(v["image_base64"].(string))
	if e != nil {
		t.Fatal(e)
	}
	image, e := png.Decode(bytes.NewReader(data))
	if e != nil || image.Bounds().Dx() != 180 || image.Bounds().Dy() != 60 {
		t.Fatalf("image %v", e)
	}
	if _, leaked := v["answer"]; leaked {
		t.Fatal("answer leaked")
	}
	if _, ok := c.issue(r); ok {
		t.Fatal("refresh flood")
	}
	if c.consume(r, "", "") {
		t.Fatal("empty challenge")
	}
	id := seedLoginCaptcha(c, "192.0.2.3")
	if c.consume(r, id, "00000") || c.consume(r, id, "12345") {
		t.Fatal("wrong answer/replay")
	}
	id = seedLoginCaptcha(c, "192.0.2.4")
	r.Header.Set("X-Forwarded-For", "192.0.2.4")
	if c.consume(r, id, "12345") {
		t.Fatal("forwarded peer bypass")
	}
	id = seedLoginCaptcha(c, "192.0.2.3")
	now = now.Add(loginCaptchaTTL)
	if c.consume(r, id, "12345") {
		t.Fatal("expired challenge")
	}
	id = seedLoginCaptcha(c, "192.0.2.3")
	var successes atomic.Int32
	var workers sync.WaitGroup
	for i := 0; i < 16; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			if c.consume(r, id, "12345") {
				successes.Add(1)
			}
		}()
	}
	workers.Wait()
	if successes.Load() != 1 {
		t.Fatal("concurrent replay", successes.Load())
	}
}

func TestLoginCaptchaCapacityAndRefresh(t *testing.T) {
	c := newLoginCaptchas()
	now := time.Now()
	c.now = func() time.Time { return now }
	r := httptest.NewRequest("GET", "https://example.invalid"+loginCaptchaPath, nil)
	r.RemoteAddr = "192.0.2.3:1234"
	for i := 0; i < 8; i++ {
		if _, ok := c.issue(r); !ok {
			t.Fatal("refresh")
		}
		now = now.Add(time.Second)
	}
	if len(c.entries) != 4 {
		t.Fatal("per-peer bound", len(c.entries))
	}
	for len(c.entries) < loginCaptchaCapacity {
		seedLoginCaptcha(c, "192.0.2.99")
	}
	if _, ok := c.issue(r); ok {
		t.Fatal("global capacity")
	}
	now = now.Add(loginCaptchaTTL)
	if _, ok := c.issue(r); !ok || len(c.entries) != 1 || len(c.peers) != 1 {
		t.Fatal("expiry did not recover capacity")
	}
}
