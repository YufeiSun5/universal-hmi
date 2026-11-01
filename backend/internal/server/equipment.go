package server

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/equipment"
)

func EquipmentHandler(next http.Handler, s *equipment.Service, origin string) http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any, e error) {
		if errors.Is(e, equipment.ErrMissing) {
			writeError(w, 404, "not_found", e.Error())
			return
		}
		if errors.Is(e, equipment.ErrConflict) {
			writeError(w, 409, "revision_conflict", e.Error())
			return
		}
		outcome(w, v, e)
	}
	mux.HandleFunc("GET /api/v1/equipment-navigation", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Navigation(r.Context())
		w.Header().Set("Cache-Control", "no-store")
		reply(w, v, e)
	})
	mux.HandleFunc("PUT /api/v1/equipment-navigation", func(w http.ResponseWriter, r *http.Request) {
		var c equipment.Navigation
		if !decode(w, r, &c) {
			return
		}
		v, e := s.SaveNavigation(r.Context(), c)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/equipment/status", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Statuses(r.Context(), strings.Split(r.URL.Query().Get("ids"), ","))
		w.Header().Set("Cache-Control", "no-store")
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("GET /api/v1/equipment", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		limit, offset := 50, 0
		var e error
		if q.Get("offset") != "" {
			offset, e = strconv.Atoi(q.Get("offset"))
		}
		if e != nil {
			writeError(w, 400, "invalid_request", "分页参数无效")
			return
		}
		if q.Get("limit") != "" {
			limit, e = strconv.Atoi(q.Get("limit"))
		}
		if e != nil {
			writeError(w, 400, "invalid_request", "分页参数无效")
			return
		}
		v, e := s.List(r.Context(), equipment.Filter{Station: q.Get("station"), Site: q.Get("site"), Category: q.Get("category"), Status: q.Get("status"), Search: q.Get("search"), Location: q.Get("location"), Offset: offset, Limit: limit})
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/equipment/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Get(r.Context(), r.PathValue("id"))
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/equipment", func(w http.ResponseWriter, r *http.Request) {
		var d equipment.Device
		if !decode(w, r, &d) {
			return
		}
		v, e := s.Save(r.Context(), d)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/equipment/{id}/photos", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Revision int64  `json:"revision"`
			Name     string `json:"name"`
			Data     []byte `json:"data"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 3*1024*1024))
		dec.DisallowUnknownFields()
		if e := dec.Decode(&in); e != nil {
			writeError(w, 400, "invalid_image", "图片请求无效或超过2 MiB")
			return
		}
		if e := dec.Decode(new(any)); e != io.EOF {
			writeError(w, 400, "invalid_request", "请求格式无效")
			return
		}
		v, e := s.AddPhoto(r.Context(), r.PathValue("id"), in.Revision, in.Name, in.Data)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/equipment/{id}/photos/{photo}", func(w http.ResponseWriter, r *http.Request) {
		p, b, e := s.Photo(r.Context(), r.PathValue("id"), r.PathValue("photo"))
		w.Header().Set("Cache-Control", "no-store")
		reply(w, map[string]any{"photo": p, "data": base64.StdEncoding.EncodeToString(b)}, e)
	})
	mux.HandleFunc("DELETE /api/v1/equipment/{id}/photos/{photo}", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Revision int64 `json:"revision"`
		}
		if !decode(w, r, &in) {
			return
		}
		v, e := s.RemovePhoto(r.Context(), r.PathValue("id"), r.PathValue("photo"), in.Revision)
		reply(w, v, e)
	})
	guarded := originGuard(permissionGuard(configurationMutationGuard(mux)), origin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/equipment-navigation" || r.URL.Path == "/api/v1/equipment" || strings.HasPrefix(r.URL.Path, "/api/v1/equipment/") {
			guarded.ServeHTTP(w, r)
		} else {
			next.ServeHTTP(w, r)
		}
	})
}
