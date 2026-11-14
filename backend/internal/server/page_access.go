package server

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/pageaccess"
	"net/http"
)

func PageAccessHandler(next http.Handler, s *pageaccess.Service, origin string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/page-access", func(w http.ResponseWriter, r *http.Request) { v, e := s.Catalog(r.Context()); outcome(w, v, e) })
	mux.HandleFunc("POST /api/v1/account/home", func(w http.ResponseWriter, r *http.Request) {
		var in identity.Preferences
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveHome(r.Context(), in)
		if errors.Is(e, identity.ErrPreferenceConflict) {
			writeError(w, 409, "revision_conflict", e.Error())
			return
		}
		outcome(w, v, e)
	})
	guarded := originGuard(permissionGuard(mux), origin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/page-access" || r.URL.Path == "/api/v1/account/home" {
			w.Header().Set("Cache-Control", "no-store")
			guarded.ServeHTTP(w, r)
		} else {
			next.ServeHTTP(w, r)
		}
	})
}
