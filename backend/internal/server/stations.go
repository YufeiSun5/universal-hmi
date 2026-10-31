package server

import (
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
	"net/http"
)

func registerStations(mux *http.ServeMux, service *stations.Service) {
	mux.HandleFunc("GET /api/v1/stations", func(w http.ResponseWriter, r *http.Request) {
		items, err := service.List()
		if a, managed := authorization.FromContext(r.Context()); managed && err == nil {
			if !a.Active() {
				outcome(w, nil, authorization.ErrDenied)
				return
			}
			visible := make([]stations.Station, 0)
			for _, st := range items {
				if a.Station(st.Name) {
					visible = append(visible, st)
				}
			}
			items = visible
		}
		outcome(w, map[string]any{"items": items}, err)
	})
	mux.HandleFunc("POST /api/v1/stations", func(w http.ResponseWriter, r *http.Request) {
		var in stations.Station
		if !decode(w, r, &in) {
			return
		}
		st, err := service.Create(in.Name)
		if errors.Is(err, stations.ErrInvalid) {
			writeError(w, 400, "invalid_station", err.Error())
			return
		}
		if errors.Is(err, stations.ErrExists) {
			writeError(w, 409, "station_exists", "该站点已存在，请使用其他名称")
			return
		}
		outcome(w, st, err)
	})
}
