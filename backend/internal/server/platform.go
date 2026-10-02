package server

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/acquisition"
	"github.com/YufeiSun5/universal-hmi/backend/internal/analysis"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"io"
	"math"
	"net/http"
	"strconv"
	"time"
)

func decode(w http.ResponseWriter, r *http.Request, out any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024*1024))
	d.DisallowUnknownFields()
	if err := d.Decode(out); err != nil {
		writeError(w, 400, "invalid_request", err.Error())
		return false
	}
	if err := d.Decode(new(any)); err != io.EOF {
		writeError(w, 400, "invalid_request", "expected one JSON object")
		return false
	}
	return true
}
func outcome(w http.ResponseWriter, v any, err error) {
	if err != nil {
		writeError(w, 422, "operation_failed", err.Error())
		return
	}
	writeJSON(w, 200, v)
}
func filter(r *http.Request) (storage.Filter, error) {
	q := r.URL.Query()
	f := storage.Filter{PointID: q.Get("point_id"), Station: q.Get("station"), Quality: q.Get("quality"), Limit: 1000}
	for key, p := range map[string]*int64{"from": &f.From, "to": &f.To, "before": &f.Before, "after": &f.After} {
		if q.Get(key) != "" {
			n, err := strconv.ParseInt(q.Get(key), 10, 64)
			if err != nil || n < 0 && !(key == "before" && n == -1) {
				return f, fmt.Errorf("invalid %s", key)
			}
			*p = n
		}
	}
	for key, p := range map[string]*int{"limit": &f.Limit, "offset": &f.Offset} {
		if q.Get(key) != "" {
			n, err := strconv.Atoi(q.Get(key))
			if err != nil || n < 0 || key == "limit" && (n < 1 || n > 5000) {
				return f, fmt.Errorf("invalid %s", key)
			}
			*p = n
		}
	}
	for _, key := range []string{"min", "max"} {
		if q.Get(key) != "" {
			n, err := strconv.ParseFloat(q.Get(key), 64)
			if err != nil || math.IsNaN(n) || math.IsInf(n, 0) {
				return f, fmt.Errorf("finite numeric filter required")
			}
			if key == "min" {
				f.Min = &n
			} else {
				f.Max = &n
			}
		}
	}
	if f.From > 0 && f.To > 0 && f.From > f.To {
		return f, fmt.Errorf("time range reversed")
	}
	return f, nil
}
func PlatformHandler(ps *points.Service, e *rt.Engine, files *analysis.Service, webDir, devOrigin string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/history/catalog", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		limit := storage.MaxCatalog
		if r.URL.Query().Get("limit") != "" {
			var err error
			limit, err = strconv.Atoi(r.URL.Query().Get("limit"))
			if err != nil || limit < 1 || limit > storage.MaxCatalog {
				outcome(w, nil, fmt.Errorf("catalog limit must be 1..%d", storage.MaxCatalog))
				return
			}
		}
		items, err := e.Store.CatalogPage(ctx, r.URL.Query().Get("station"), limit)
		outcome(w, items, err)
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok", "service": "universal-hmi", "capabilities": map[string]bool{"point_configuration": true, "acquisition": true, "events": true, "history": true, "analysis": true}})
	})
	mux.HandleFunc("GET /api/v1/runtime", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, e.Snapshot()) })
	mux.HandleFunc("POST /api/v1/apply", func(w http.ResponseWriter, r *http.Request) {
		version, err := e.Apply()
		outcome(w, map[string]any{"version": version}, err)
	})
	mux.HandleFunc("PUT /api/v1/points/{id}", func(w http.ResponseWriter, r *http.Request) {
		var in points.CreateInput
		if !decode(w, r, &in) {
			return
		}
		p, err := ps.Update(r.PathValue("id"), in)
		outcome(w, p, err)
	})
	mux.HandleFunc("DELETE /api/v1/points/{id}", func(w http.ResponseWriter, r *http.Request) {
		err := ps.Delete(r.PathValue("id"))
		outcome(w, map[string]any{"deleted": err == nil}, err)
	})
	mux.HandleFunc("POST /api/v1/points/{id}/sample", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Value any `json:"value"`
		}
		if !decode(w, r, &in) {
			return
		}
		err := e.Manual(r.PathValue("id"), in.Value)
		outcome(w, map[string]any{"accepted": err == nil}, err)
	})
	mux.HandleFunc("POST /api/v1/write", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			CommandID string   `json:"command_id"`
			PointID   string   `json:"point_id"`
			Value     *float64 `json:"value"`
			Version   string   `json:"version"`
		}
		if !decode(w, r, &in) {
			return
		}
		if in.Value == nil {
			writeError(w, 400, "value_required", "value must be an explicit number")
			return
		}
		result, err := e.Write(rt.Write{CommandID: in.CommandID, PointID: in.PointID, Value: *in.Value, Version: in.Version})
		outcome(w, result, err)
	})
	mux.HandleFunc("PUT /api/v1/sources", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Items []acquisition.Source `json:"items"`
		}
		if !decode(w, r, &in) {
			return
		}
		err := e.Sources(in.Items)
		outcome(w, map[string]any{"saved": err == nil}, err)
	})
	mux.HandleFunc("POST /api/v1/sources/{id}/connect", func(w http.ResponseWriter, r *http.Request) {
		err := e.Connect(r.PathValue("id"))
		outcome(w, map[string]any{"connected": err == nil}, err)
	})
	mux.HandleFunc("POST /api/v1/sources/{id}/disconnect", func(w http.ResponseWriter, r *http.Request) {
		e.Disconnect(r.PathValue("id"))
		writeJSON(w, 200, map[string]any{"disconnected": true})
	})
	mux.HandleFunc("GET /api/v1/storage", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, e.StoragePolicy(r.URL.Query().Get("station")))
	})
	mux.HandleFunc("GET /api/v1/points/{id}/write-capability", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, e.WriteCapability(r.PathValue("id"))) })
	mux.HandleFunc("GET /api/v1/commands/{id}", func(w http.ResponseWriter, r *http.Request) {
		result, err := e.Command(r.PathValue("id"))
		outcome(w, result, err)
	})
	mux.HandleFunc("POST /api/v1/points/batch", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Items []points.CreateInput `json:"items"`
		}
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024*1024))
		d.DisallowUnknownFields()
		if err := d.Decode(&in); err != nil {
			writeError(w, 400, "invalid_request", err.Error())
			return
		}
		if err := d.Decode(new(any)); err != io.EOF {
			writeError(w, 400, "invalid_request", "expected one JSON object")
			return
		}
		rows, err := ps.CreateBatch(in.Items)
		outcome(w, map[string]any{"items": rows}, err)
	})
	mux.HandleFunc("PUT /api/v1/storage", func(w http.ResponseWriter, r *http.Request) {
		var in rt.Policy
		if !decode(w, r, &in) {
			return
		}
		err := e.SetPolicy(r.URL.Query().Get("station"), in)
		outcome(w, map[string]any{"saved": err == nil}, err)
	})
	mux.HandleFunc("POST /api/v1/snapshot", func(w http.ResponseWriter, r *http.Request) {
		err := e.SnapshotStation(r.URL.Query().Get("station"))
		outcome(w, map[string]any{"stored": err == nil}, err)
	})
	mux.HandleFunc("GET /api/v1/history", func(w http.ResponseWriter, r *http.Request) {
		f, err := filter(r)
		if err != nil {
			outcome(w, nil, err)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		// Freeze one query boundary shared by rows, statistics and subsequent pages/export.
		if f.Before == 0 {
			f.Before, err = e.Store.Boundary()
			if err != nil {
				outcome(w, nil, err)
				return
			}
		}
		if f.Before == 0 {
			f.Before = -1
		}
		rows, err := e.Store.Query(ctx, f)
		if err != nil {
			outcome(w, nil, err)
			return
		}
		stats, err := e.Store.Stats(ctx, f)
		outcome(w, map[string]any{"items": rows, "stats": stats, "boundary": f.Before, "offset": f.Offset, "limit": f.Limit}, err)
	})
	mux.HandleFunc("PUT /api/v1/rules", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Items []rt.Rule `json:"items"`
		}
		if !decode(w, r, &in) {
			return
		}
		err := e.SetRules(in.Items)
		outcome(w, map[string]any{"saved": err == nil}, err)
	})
	mux.HandleFunc("POST /api/v1/rules/preview", func(w http.ResponseWriter, r *http.Request) {
		var in rt.Rule
		if !decode(w, r, &in) {
			return
		}
		writeJSON(w, 200, e.Preview(in))
	})
	mux.HandleFunc("GET /api/v1/executions", func(w http.ResponseWriter, r *http.Request) {
		rows, err := e.Store.Logs()
		outcome(w, map[string]any{"items": rows}, err)
	})
	mux.HandleFunc("POST /api/v1/demo", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Enabled bool `json:"enabled"`
		}
		if !decode(w, r, &in) {
			return
		}
		err := e.Demo(in.Enabled)
		outcome(w, map[string]any{"enabled": in.Enabled}, err)
	})
	mux.HandleFunc("POST /api/v1/import/upload", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 8*1024*1024)
		if err := r.ParseMultipartForm(1024 * 1024); err != nil {
			outcome(w, nil, err)
			return
		}
		defer r.MultipartForm.RemoveAll()
		file, header, err := r.FormFile("file")
		if err != nil {
			outcome(w, nil, err)
			return
		}
		defer file.Close()
		result, err := files.Upload(file, header.Filename)
		outcome(w, result, err)
	})
	mux.HandleFunc("POST /api/v1/import/preview", func(w http.ResponseWriter, r *http.Request) {
		var in analysis.Mapping
		if !decode(w, r, &in) {
			return
		}
		result, err := files.Preview(in, false)
		outcome(w, result, err)
	})
	mux.HandleFunc("POST /api/v1/import/commit", func(w http.ResponseWriter, r *http.Request) {
		var in analysis.Mapping
		if !decode(w, r, &in) {
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		result, err := files.Import(ctx, in)
		outcome(w, result, err)
	})
	mux.HandleFunc("POST /api/v1/export", func(w http.ResponseWriter, r *http.Request) {
		f, err := filter(r)
		if err != nil {
			outcome(w, nil, err)
			return
		}
		job, err := files.Export(f, r.URL.Query().Get("format"))
		outcome(w, job, err)
	})
	mux.HandleFunc("GET /api/v1/jobs", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]any{"items": files.Jobs()}) })
	mux.HandleFunc("POST /api/v1/jobs/{id}/cancel", func(w http.ResponseWriter, r *http.Request) {
		err := files.Cancel(r.PathValue("id"))
		outcome(w, map[string]any{"cancelled": err == nil}, err)
	})
	mux.HandleFunc("DELETE /api/v1/jobs/{id}", func(w http.ResponseWriter, r *http.Request) {
		err := files.Remove(r.PathValue("id"))
		outcome(w, map[string]any{"removed": err == nil}, err)
	})
	mux.HandleFunc("GET /api/v1/jobs/{id}/file", func(w http.ResponseWriter, r *http.Request) {
		path, format, err := files.File(r.PathValue("id"))
		if err != nil {
			outcome(w, nil, err)
			return
		}
		w.Header().Set("Content-Disposition", "attachment; filename=\"universal-hmi."+format+"\"")
		if format == "xlsx" {
			w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
		} else {
			w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		}
		http.ServeFile(w, r, path)
	})
	base := Handler(ps, webDir, devOrigin)
	// Root handler keeps all configuration transport and origin enforcement in one place.
	mux.Handle("/", base)
	return originGuard(mux, devOrigin)
}
