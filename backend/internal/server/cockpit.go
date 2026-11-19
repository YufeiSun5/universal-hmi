package server

import (
	"errors"
	"net/http"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/cockpit"
)

func CockpitHandler(next http.Handler, service *cockpit.Service, devOrigin string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/cockpit", func(w http.ResponseWriter, r *http.Request) {
		c, err := service.Get(r.Context())
		outcome(w, c, err)
	})
	mux.HandleFunc("PUT /api/v1/cockpit", func(w http.ResponseWriter, r *http.Request) {
		var c cockpit.ConfigChange
		if !decode(w, r, &c) {
			return
		}
		saved, err := service.Save(r.Context(), c)
		if errors.Is(err, cockpit.ErrConflict) {
			writeError(w, http.StatusConflict, "cockpit_conflict", err.Error())
			return
		}
		outcome(w, saved, err)
	})
	mux.HandleFunc("GET /api/v1/cockpit/live", func(w http.ResponseWriter, r *http.Request) {
		v, err := service.Live(r.Context())
		outcome(w, v, err)
	})
	mux.HandleFunc("GET /api/v1/cockpit/history", func(w http.ResponseWriter, r *http.Request) {
		v, err := service.History(r.Context())
		outcome(w, v, err)
	})
	mux.HandleFunc("GET /api/v1/cockpit/weather", func(w http.ResponseWriter, r *http.Request) {
		v, err := service.Weather(r.Context())
		outcome(w, v, err)
	})
	guarded := originGuard(permissionGuard(configurationMutationGuard(mux)), devOrigin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/cockpit" || strings.HasPrefix(r.URL.Path, "/api/v1/cockpit/") {
			guarded.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
