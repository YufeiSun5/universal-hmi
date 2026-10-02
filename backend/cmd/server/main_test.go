package main

import "testing"

func TestValidateListenFailClosed(t *testing.T) {
	for _, tc := range []struct {
		name, listen, auth, origin, cert, key, dev string
		allowed                                    bool
	}{
		{"default local", "127.0.0.1:18080", "", "", "", "", "", true},
		{"local ipv6", "[::1]:18080", "", "", "", "", "", true},
		{"localhost", "localhost:18080", "", "", "", "", "", true},
		{"local dev", "127.0.0.1:18080", "", "", "", "", "http://localhost:8080", true},
		{"wildcard", ":18080", "", "", "", "", "", false},
		{"lan", "192.0.2.1:18080", "", "", "", "", "", false},
		{"dns loopback claim", "local.example:18080", "", "", "", "", "", false},
		{"partial tls", "127.0.0.1:18080", "", "", "cert", "", "", false},
		{"auth plaintext local", "127.0.0.1:18080", "account", "http://127.0.0.1:18080", "", "", "", false},
		{"remote plaintext", "0.0.0.0:18080", "account", "https://hmi.example:18080", "", "", "", false},
		{"remote tls no auth", "0.0.0.0:18080", "", "", "cert", "key", "", false},
		{"remote secure", "0.0.0.0:18080", "account", "https://hmi.example:18080", "cert", "key", "", true},
		{"local secure", "127.0.0.1:18080", "account", "https://127.0.0.1:18080", "cert", "key", "", true},
		{"no origin", "127.0.0.1:18080", "account", "", "cert", "key", "", false},
		{"insecure origin", "127.0.0.1:18080", "account", "http://127.0.0.1:18080", "cert", "key", "", false},
		{"origin credentials", "127.0.0.1:18080", "account", "https://user@hmi.example", "cert", "key", "", false},
		{"origin path", "127.0.0.1:18080", "account", "https://hmi.example/", "cert", "key", "", false},
		{"origin query", "127.0.0.1:18080", "account", "https://hmi.example?foo", "cert", "key", "", false},
		{"dev origin bypass", "127.0.0.1:18080", "account", "https://hmi.example", "cert", "key", "https://other.example", false},
		{"orphan origin", "127.0.0.1:18080", "", "https://hmi.example", "", "", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := validateListen(tc.listen, tc.auth, tc.origin, tc.cert, tc.key, tc.dev); (err == nil) != tc.allowed {
				t.Fatalf("allowed=%v, error=%v", tc.allowed, err)
			}
		})
	}
}
