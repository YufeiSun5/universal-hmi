package server

import (
	"errors"
	"net/http"

	"github.com/YufeiSun5/universal-hmi/backend/internal/overview"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

func registerOverview(mux *http.ServeMux, store overview.Store, ps *points.Service, station func(string) error) {
	svc := overview.New(store)
	respond := func(w http.ResponseWriter, c overview.Config, err error) {
		if errors.Is(err, overview.ErrConflict) {
			writeError(w, 409, "overview_conflict", "总览已被其他窗口修改；当前草稿保留，请取消后刷新再编辑")
			return
		}
		outcome(w, c, err)
	}
	mux.HandleFunc("GET /api/v1/live-overview", func(w http.ResponseWriter, r *http.Request) {
		rows, err := ps.Visible(r.Context())
		if err != nil {
			outcome(w, nil, err)
			return
		}
		visible := map[string]bool{}
		for _, p := range rows {
			visible[p.ID] = true
		}
		c, err := svc.Get(r.Context(), visible)
		respond(w, c, err)
	})
	mux.HandleFunc("PUT /api/v1/live-overview", func(w http.ResponseWriter, r *http.Request) {
		var c overview.Config
		if !decode(w, r, &c) {
			return
		}
		rows, err := ps.Visible(r.Context())
		if err != nil {
			outcome(w, nil, err)
			return
		}
		visible := map[string]bool{}
		for _, p := range rows {
			visible[p.ID] = true
		}
		c, err = svc.Save(r.Context(), c, visible, station)
		respond(w, c, err)
	})
}
