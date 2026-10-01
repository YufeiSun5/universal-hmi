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
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi",
			"capabilities": map[string]bool{"point_configuration": true, "acquisition": false,
				"events": false, "history": false, "analysis": false}})
	})
	mux.HandleFunc("GET /api/v1/points", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"items": service.List()})
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
	return originGuard(mux,devOrigin)
}
func originGuard(mux http.Handler,devOrigin string)http.Handler{
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
		if r.Method != http.MethodGet && r.Method != http.MethodHead &&
			origin != "" && origin != "http://"+r.Host && origin != devOrigin {
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
