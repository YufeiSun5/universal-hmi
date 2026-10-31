package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// Desktop fallback holds the selected listener continuously; a port probe
// followed by a second bind would race other processes.
func desktopListener(address string, auto bool) (net.Listener, error) {
	if auto {
		host, _, err := net.SplitHostPort(address)
		if err != nil || host != "127.0.0.1" {
			return nil, fmt.Errorf("auto-port requires a 127.0.0.1 listener")
		}
	}
	listener, err := net.Listen("tcp", address)
	if err != nil && auto {
		return net.Listen("tcp", "127.0.0.1:0")
	}
	return listener, err
}

// The client creates a private per-launch directory and validates this PID.
// Rename prevents the client from observing a partially written descriptor.
func writeDesktopEndpoint(path string, listener net.Listener) error {
	data, err := json.Marshal(struct {
		URL string `json:"url"`
		PID int    `json:"pid"`
	}{"http://" + listener.Addr().String() + "/", os.Getpid()})
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".endpoint-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
