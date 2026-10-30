package server

import (
	"errors"
	"net/http"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/externaldata"
)

// ExternalDataHandler mounts the separate project-level history module.
func ExternalDataHandler(next http.Handler, s *externaldata.Service, devOrigin string) http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any, e error) {
		if errors.Is(e, externaldata.ErrConflict) {
			writeError(w, 409, "revision_conflict", e.Error())
			return
		}
		if errors.Is(e, externaldata.ErrMissing) {
			writeError(w, 404, "not_found", e.Error())
			return
		}
		outcome(w, v, e)
	}
	mux.HandleFunc("GET /api/v1/external/sources", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Sources(r.Context())
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/external/sources", func(w http.ResponseWriter, r *http.Request) {
		var in externaldata.SourceChange
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveSource(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/external/sources/{id}/test", func(w http.ResponseWriter, r *http.Request) {
		e := s.Test(r.Context(), r.PathValue("id"))
		reply(w, map[string]any{"connected": e == nil}, e)
	})
	mux.HandleFunc("GET /api/v1/external/screens", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Screens(r.Context())
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/external/screens", func(w http.ResponseWriter, r *http.Request) {
		var in externaldata.Screen
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveScreen(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/external/screens/{id}/stations", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Stations(r.Context(), r.PathValue("id"))
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/external/screens/{id}/query", func(w http.ResponseWriter, r *http.Request) {
		var in externaldata.Request
		if !decode(w, r, &in) {
			return
		}
		v, e := s.Query(r.Context(), r.PathValue("id"), in)
		reply(w, v, e)
	})
	for _, kind := range []string{"sources", "screens"} {
		mux.HandleFunc("DELETE /api/v1/external/"+kind+"/{id}", func(w http.ResponseWriter, r *http.Request) {
			var in struct {
				Revision int64 `json:"revision"`
			}
			if !decode(w, r, &in) {
				return
			}
			e := s.Delete(r.Context(), kind, r.PathValue("id"), in.Revision)
			reply(w, map[string]any{"deleted": e == nil}, e)
		})
	}
	guarded := originGuard(permissionGuard(configurationMutationGuard(mux)), devOrigin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/v1/external/") {
			guarded.ServeHTTP(w, r)
		} else {
			next.ServeHTTP(w, r)
		}
	})
}
