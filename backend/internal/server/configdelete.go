package server

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/configdelete"
	"net/http"
)

func registerConfigDelete(mux *http.ServeMux, service *configdelete.Service) {
	for _, kind := range []string{"points", "stations"} {
		for _, action := range []string{"preview", "commit"} {
			station, commit := kind == "stations", action == "commit"
			mux.HandleFunc("POST /api/v1/"+kind+"/delete-"+action, func(w http.ResponseWriter, r *http.Request) {
				var in configdelete.Request
				if !decode(w, r, &in) {
					return
				}
				out, e := service.Run(r.Context(), in, station, commit)
				if errors.Is(e, configdelete.ErrConflict) {
					writeJSON(w, http.StatusConflict, map[string]any{"error": "delete_conflict", "message": e.Error(), "result": out})
					return
				}
				if errors.Is(e, authorization.ErrDenied) {
					writeError(w, http.StatusForbidden, "permission_denied", "engineering permission required")
					return
				}
				if e != nil {
					writeError(w, http.StatusBadRequest, "delete_rejected", "configuration deletion rejected")
					return
				}
				writeJSON(w, http.StatusOK, out)
			})
		}
	}
}
