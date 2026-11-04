package server

import (
	"net/http"
	"strings"
)

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
