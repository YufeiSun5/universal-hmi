package server

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/dchest/captcha"
)

const loginCaptchaPath = "/api/v1/auth/captcha"
const loginCaptchaTTL = 2 * time.Minute
const loginCaptchaCapacity = 4096

type loginCaptchaEntry struct {
	binding string
	answer  [32]byte
	expires time.Time
}

// Challenges are transient, bounded and tied to the real connection peer and
// device certificate. Neither forwarded headers nor a client-supplied ID grant access.
type loginCaptchas struct {
	mu      sync.Mutex
	entries map[string]loginCaptchaEntry
	peers   map[string]time.Time
	renders chan struct{}
	now     func() time.Time
}

func newLoginCaptchas() *loginCaptchas {
	return &loginCaptchas{entries: make(map[string]loginCaptchaEntry), peers: make(map[string]time.Time), renders: make(chan struct{}, 8), now: time.Now}
}

func loginCaptchaBinding(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return ""
	}
	if leaf := publicDeviceLeaf(r); leaf != nil {
		sum := sha256.Sum256(leaf.Raw)
		return host + ":" + hex.EncodeToString(sum[:])
	}
	return host
}

func (c *loginCaptchas) issue(r *http.Request) (map[string]any, bool) {
	binding := loginCaptchaBinding(r)
	if binding == "" {
		return nil, false
	}
	select {
	case c.renders <- struct{}{}:
	default:
		return nil, false
	}
	defer func() { <-c.renders }()
	now := c.now()
	c.mu.Lock()
	for id, entry := range c.entries {
		if !now.Before(entry.expires) {
			delete(c.entries, id)
		}
	}
	for peer, last := range c.peers {
		if now.Sub(last) >= loginCaptchaTTL {
			delete(c.peers, peer)
		}
	}
	last, known := c.peers[binding]
	if (known && now.Sub(last) < time.Second) || (!known && len(c.peers) >= loginCaptchaCapacity) || len(c.entries) >= loginCaptchaCapacity {
		c.mu.Unlock()
		return nil, false
	}
	// Keep up to four simultaneous forms for users behind one whitelisted IP.
	count, oldestID := 0, ""
	var oldest time.Time
	for id, entry := range c.entries {
		if entry.binding == binding {
			count++
			if oldestID == "" || entry.expires.Before(oldest) {
				oldestID, oldest = id, entry.expires
			}
		}
	}
	if count >= 4 {
		delete(c.entries, oldestID)
	}
	c.peers[binding] = now
	c.mu.Unlock()
	var random [24]byte
	if _, err := rand.Read(random[:]); err != nil {
		return nil, false
	}
	id := hex.EncodeToString(random[:])
	digits := captcha.RandomDigits(5)
	var png bytes.Buffer
	if _, err := captcha.NewImage(id, digits, 180, 60).WriteTo(&png); err != nil {
		return nil, false
	}
	for i := range digits {
		digits[i] += '0'
	}
	entry := loginCaptchaEntry{binding: binding, answer: sha256.Sum256(digits), expires: now.Add(loginCaptchaTTL)}
	c.mu.Lock()
	if len(c.entries) >= loginCaptchaCapacity {
		c.mu.Unlock()
		return nil, false
	}
	c.entries[id] = entry
	c.mu.Unlock()
	return map[string]any{"id": id, "image_base64": base64.StdEncoding.EncodeToString(png.Bytes()), "expires_at": entry.expires.UTC().Format(time.RFC3339)}, true
}

func (c *loginCaptchas) consume(r *http.Request, id, answer string) bool {
	if len(id) != 48 {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[id]
	// A submission consumes the challenge even when its answer is wrong.
	delete(c.entries, id)
	sum := sha256.Sum256([]byte(answer))
	return ok && len(answer) <= 32 && entry.binding == loginCaptchaBinding(r) && c.now().Before(entry.expires) && subtle.ConstantTimeCompare(sum[:], entry.answer[:]) == 1
}
