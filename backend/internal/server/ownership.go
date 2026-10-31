package server

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/ownership"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"net/http"
)

func registerOwnership(mux *http.ServeMux, s *ownership.Service) {
	for _, action := range []string{"preview", "commit"} {
		commit := action == "commit"
		mux.HandleFunc("POST /api/v1/points/ownership-"+action, func(w http.ResponseWriter, r *http.Request) {
			var in ownership.Request
			if !decode(w, r, &in) {
				return
			}
			out, err := s.Run(r.Context(), in, commit)
			if errors.Is(err, authorization.ErrDenied) {
				writeError(w, 403, "permission_denied", "engineering and station permissions required")
				return
			}
			if errors.Is(err, ownership.ErrConflict) || errors.Is(err, points.ErrInvalid) {
				writeJSON(w, 409, map[string]any{"error": "ownership_conflict", "message": "归属计划已变化或存在阻断，请重新预览", "result": out})
				return
			}
			if err != nil {
				writeError(w, 422, "ownership_rejected", "归属整理未保存，请重新预览并核对依赖和备份存储")
				return
			}
			writeJSON(w, 200, out)
		})
	}
}
