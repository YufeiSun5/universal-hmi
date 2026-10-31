// Standalone, loopback-only demonstration server. Not the HMI production backend.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	executable, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	root := flag.String("root", filepath.Join(filepath.Dir(executable), "site"), "public demo directory")
	port := flag.Int("port", 18149, "loopback HTTP port")
	flag.Parse()
	if *port < 1024 || *port > 65535 {
		log.Fatal("port out of range")
	}
	absolute, err := filepath.Abs(*root)
	if err != nil {
		log.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(absolute, "imagery", "manifest.json")); err != nil {
		log.Fatal("demo package incomplete: ", err)
	}
	files := http.FileServer(http.Dir(absolute))
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if host != fmt.Sprintf("127.0.0.1:%d", *port) && host != fmt.Sprintf("localhost:%d", *port) {
			http.Error(w, "loopback host required", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "read only", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-cache")
		// Runtime is deliberately same-origin only: no ion, CDN, geocoder or online tiles.
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' blob: 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; worker-src 'self' blob:; font-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self' http://127.0.0.1:* http://localhost:*")
		if r.URL.Path == "/health" {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"service":"universal-hmi-gis-demo","status":"ok"}`)
			return
		}
		clean := filepath.Join(absolute, filepath.FromSlash(r.URL.Path))
		relative, err := filepath.Rel(absolute, clean)
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			http.NotFound(w, r)
			return
		}
		info, err := os.Stat(clean)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if info.IsDir() {
			if _, err := os.Stat(filepath.Join(clean, "index.html")); err != nil {
				http.NotFound(w, r)
				return
			}
		}
		files.ServeHTTP(w, r)
	})
	address := fmt.Sprintf("127.0.0.1:%d", *port)
	log.Printf("GIS demo http://%s/ (static root %s)", address, absolute)
	server := &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
	log.Fatal(server.ListenAndServe())
}
