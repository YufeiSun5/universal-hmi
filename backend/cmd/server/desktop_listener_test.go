package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopListenerPortConflict(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	address := occupied.Addr().String()
	if listener, err := desktopListener(address, false); err == nil {
		listener.Close()
		t.Fatal("fixed deployment must reject an occupied port")
	}
	listener, err := desktopListener(address, true)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if listener.Addr().String() == address {
		t.Fatal("fallback reused occupied port")
	}
	if second, err := net.Listen("tcp", listener.Addr().String()); err == nil {
		second.Close()
		t.Fatal("selected port must remain held")
	}
	connection, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal("original listener was disturbed:", err)
	}
	connection.Close()
	path := filepath.Join(t.TempDir(), "endpoint.json")
	if err := writeDesktopEndpoint(path, listener); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var endpoint struct {
		URL string
		PID int
	}
	if err := json.Unmarshal(data, &endpoint); err != nil {
		t.Fatal(err)
	}
	if endpoint.PID != os.Getpid() || endpoint.URL != "http://"+listener.Addr().String()+"/" {
		t.Fatalf("invalid launch descriptor: %s", data)
	}
}

func TestDesktopListenerPreferredAndScope(t *testing.T) {
	reservation, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reservation.Addr().String()
	reservation.Close()
	listener, err := desktopListener(address, true)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if listener.Addr().String() != address {
		t.Fatal("free preferred port not used")
	}
	for _, address := range []string{"0.0.0.0:0", "[::1]:0", "localhost:0", "invalid"} {
		if listener, err := desktopListener(address, true); err == nil {
			listener.Close()
			t.Fatalf("unsafe auto-port address accepted: %s", address)
		}
	}
}
