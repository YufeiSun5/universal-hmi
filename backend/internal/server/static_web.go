package server

import (
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// WebFiles serves build-time compressed public assets after the caller's
// authentication/admission boundary. API responses never enter this handler.
func WebFiles(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/")
		ext := strings.ToLower(filepath.Ext(name))
		compressible := ext == ".js" || ext == ".mjs" || ext == ".wasm" || ext == ".css" || ext == ".json" || ext == ".ttf" || ext == ".otf" || ext == ".svg"
		if compressible {
			w.Header().Add("Vary", "Accept-Encoding")
		}
		if compressible && (r.Method == "GET" || r.Method == "HEAD") && r.Header.Get("Range") == "" && acceptsGzip(r.Header.Get("Accept-Encoding")) && path.Clean(name) == name && !strings.Contains(name, "\\") && !strings.HasPrefix(name, ".") {
			original, err := os.Stat(filepath.Join(dir, filepath.FromSlash(name)))
			if err == nil && original.Mode().IsRegular() {
				file, err := os.Open(filepath.Join(dir, filepath.FromSlash(name)) + ".gz")
				if err == nil {
					defer file.Close()
					info, err := file.Stat()
					if err == nil && info.Mode().IsRegular() && !info.ModTime().Before(original.ModTime()) {
						kind := mime.TypeByExtension(ext)
						if ext == ".wasm" {
							kind = "application/wasm"
						}
						if kind == "" {
							kind = "application/octet-stream"
						}
						w.Header().Set("Content-Type", kind)
						w.Header().Set("Content-Encoding", "gzip")
						http.ServeContent(w, r, name, info.ModTime(), file)
						return
					}
				}
			}
		}
		files.ServeHTTP(w, r)
	})
}

func acceptsGzip(value string) bool {
	for _, item := range strings.Split(value, ",") {
		parts := strings.Split(item, ";")
		if !strings.EqualFold(strings.TrimSpace(parts[0]), "gzip") {
			continue
		}
		quality := 1.0
		for _, param := range parts[1:] {
			key, val, ok := strings.Cut(strings.TrimSpace(param), "=")
			if ok && strings.EqualFold(key, "q") {
				parsed, err := strconv.ParseFloat(val, 64)
				if err != nil {
					return false
				}
				quality = parsed
			}
		}
		return quality > 0 && quality <= 1
	}
	return false
}

// RevalidatingWebAssets wraps only the frontend file server, inside the identity
// and public admission boundaries. APIs and denied requests never reach it.
func RevalidatingWebAssets(files http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if (r.Method == http.MethodGet || r.Method == http.MethodHead) &&
			(p == "/main.dart.js" || p == "/main.dart.wasm" || p == "/main.dart.mjs" ||
				strings.HasPrefix(p, "/canvaskit/") || strings.HasPrefix(p, "/assets/")) {
			w.Header().Set("Cache-Control", "private, no-cache")
		}
		files.ServeHTTP(w, r)
	})
}
