package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func Handler(service *points.Service, webDir, devOrigin string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/blank.html", func(w http.ResponseWriter, r *http.Request) {
		// Local KP containers use a different port. This inert page has no
		// application content and must remain embeddable across local origins.
		serveBlankPage(w, r, "")
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi",
			"capabilities": map[string]bool{"point_configuration": true, "acquisition": false,
				"events": false, "history": false, "analysis": false}})
	})
	mux.HandleFunc("GET /api/v1/points", func(w http.ResponseWriter, r *http.Request) {
		items, err := service.Visible(r.Context())
		outcome(w, map[string]any{"items": items}, err)
	})
	mux.HandleFunc("POST /api/v1/points", func(w http.ResponseWriter, r *http.Request) {
		var input points.CreateInput
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024*1024))
		d.DisallowUnknownFields()
		if err := d.Decode(&input); err != nil {
			writeError(w, 400, "invalid_request", "Invalid point configuration")
			return
		}
		if err := d.Decode(new(any)); err != io.EOF {
			writeError(w, 400, "invalid_request", "Expected one JSON object")
			return
		}
		p, err := service.Create(input)
		if errors.Is(err, points.ErrInvalid) {
			writeError(w, 422, "invalid_point", err.Error())
			return
		}
		if err != nil {
			writeError(w, 500, "save_failed", "Point configuration was not saved")
			return
		}
		writeJSON(w, 201, p)
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, 404, "not_found", "API operation is not available")
	})
	if webDir != "" {
		mux.Handle("/", http.FileServer(http.Dir(webDir)))
	}
	return originGuard(permissionGuard(configurationMutationGuard(mux)), devOrigin)
}

// serveBlankPage supplies an inert HTTP(S) navigation target for KP containers
// that reject about: URLs. It does not load Flutter or depend on Web build files.
func serveBlankPage(w http.ResponseWriter, r *http.Request, frames string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	policy := "default-src 'none'; base-uri 'none'; form-action 'none'"
	if frames != "" {
		policy += "; frame-ancestors " + frames
	}
	w.Header().Set("Content-Security-Policy", policy)
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		authMethodError(w)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		_, _ = io.WriteString(w, "<!doctype html><html><head><meta charset=\"utf-8\"><title></title></head><body></body></html>")
	}
}

func originGuard(mux http.Handler, devOrigin string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if devOrigin != "" && origin == devOrigin {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Add("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		// Mutating browser requests must be same-origin or explicitly allowed.
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead &&
			origin != "" && origin != scheme+"://"+r.Host && origin != devOrigin {
			writeError(w, 403, "origin_rejected", "Origin is not allowed")
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
