package server

import (
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/stations"
	"github.com/YufeiSun5/universal-hmi/backend/internal/transfer"
	"io"
	"net/http"
	"path/filepath"
	"strings"
)

func registerTransfer(mux *http.ServeMux, p *points.Service, sc *process.Service, sources func() []map[string]string, stationService *stations.Service, nav *navigation.Service) {
	s := transfer.New(p, sc)
	s.Navigation = nav
	s.Sources = sources
	s.Stations = stationService
	read := func(w http.ResponseWriter, r *http.Request, v any) bool {
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, transfer.MaxBytes))
		d.DisallowUnknownFields()
		if e := d.Decode(v); e != nil {
			writeError(w, 400, "invalid_transfer", e.Error())
			return false
		}
		if d.Decode(new(any)) != io.EOF {
			writeError(w, 400, "invalid_transfer", "expected one object")
			return false
		}
		return true
	}
	outcome := func(w http.ResponseWriter, v any, e error) {
		if e != nil {
			writeError(w, 422, "transfer_failed", e.Error())
			return
		}
		writeJSON(w, 200, v)
	}
	mux.HandleFunc("GET /api/v1/process-transfer/catalog", func(w http.ResponseWriter, r *http.Request) { v, e := s.Catalog(r.Context()); outcome(w, v, e) })
	for _, action := range []string{"preview", "commit"} {
		mux.HandleFunc("POST /api/v1/process-transfer/"+action, func(w http.ResponseWriter, r *http.Request) {
			var req transfer.Request
			if !read(w, r, &req) {
				return
			}
			var v transfer.Result
			var e error
			if action == "commit" {
				v, e = s.Commit(r.Context(), req)
			} else {
				v, e = s.Preview(r.Context(), req)
			}
			outcome(w, v, e)
		})
	}
	mux.HandleFunc("POST /api/v1/process-transfer/decode", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, transfer.MaxBytes)
		if e := r.ParseMultipartForm(transfer.MaxBytes); e != nil {
			outcome(w, nil, e)
			return
		}
		defer r.MultipartForm.RemoveAll()
		f, h, e := r.FormFile("file")
		if e != nil {
			outcome(w, nil, e)
			return
		}
		defer f.Close()
		data, e := io.ReadAll(io.LimitReader(f, transfer.MaxBytes+1))
		if e != nil {
			outcome(w, nil, e)
			return
		}
		format := strings.TrimPrefix(strings.ToLower(filepath.Ext(h.Filename)), ".")
		if format == "json" {
			var wrapper struct {
				RetryRequest *transfer.Request `json:"retry_request"`
			}
			if json.Unmarshal(data, &wrapper) == nil && wrapper.RetryRequest != nil {
				outcome(w, map[string]any{"bundle": wrapper.RetryRequest.Bundle, "retry_request": wrapper.RetryRequest}, nil)
				return
			}
		}
		b, e := transfer.Decode(data, format, r.FormValue("kind"))
		if e != nil && format == "json" {
			var d process.Document
			if json.Unmarshal(data, &d) == nil && process.Validate(d) == nil {
				raw, _ := json.Marshal(transfer.Screen{Key: d.ID, Document: d})
				b = transfer.Bundle{Format: transfer.Format, Version: 1, Screens: []json.RawMessage{raw}}
				e = nil
			}
		}
		outcome(w, map[string]any{"bundle": b}, e)
	})
	mux.HandleFunc("POST /api/v1/process-transfer/export", func(w http.ResponseWriter, r *http.Request) {
		var req transfer.ExportRequest
		if !read(w, r, &req) {
			return
		}
		b, e := s.Export(r.Context(), req)
		if e != nil {
			outcome(w, nil, e)
			return
		}
		data, e := transfer.Encode(b, req.Format, req.Kind)
		if e != nil {
			outcome(w, nil, e)
			return
		}
		ct := map[string]string{"json": "application/json", "csv": "text/csv; charset=utf-8", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}[req.Format]
		w.Header().Set("Content-Type", ct)
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="process-transfer.%s"`, req.Format))
		w.WriteHeader(200)
		_, _ = w.Write(data)
	})
}
