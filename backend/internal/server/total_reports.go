package server

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/totalreports"
)

func TotalReportsHandler(next http.Handler, s *totalreports.Service, origin string) http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any, e error) {
		w.Header().Set("Cache-Control", "no-store")
		if errors.Is(e, totalreports.ErrLocked) {
			writeError(w, 409, "cell_locked", strings.ReplaceAll(e.Error(), totalreports.ErrConflict.Error()+"\n", ""))
			return
		}
		if errors.Is(e, totalreports.ErrConflict) {
			writeError(w, 409, "revision_conflict", e.Error())
			return
		}
		if errors.Is(e, totalreports.ErrMissing) {
			writeError(w, 404, "not_found", e.Error())
			return
		}
		outcome(w, v, e)
	}
	year := func(r *http.Request) int { v, _ := strconv.Atoi(r.PathValue("year")); return v }
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/design-history", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.DesignHistory(r.Context(), r.PathValue("kind"), year(r))
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/design-restore", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.DesignRestore
		if !decode(w, r, &in) {
			return
		}
		v, e := s.RestoreDesign(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	decodeFragment := func(w http.ResponseWriter, r *http.Request, v any) bool {
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 20*1024*1024))
		decoder.DisallowUnknownFields()
		if e := decoder.Decode(v); e != nil {
			reply(w, nil, fmt.Errorf("导入文件无效或过大"))
			return false
		}
		return true
	}
	mux.HandleFunc("POST /api/v1/total-reports/fragments/read", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.FragmentExcel
		if !decodeFragment(w, r, &in) {
			return
		}
		v, e := s.ReadFragmentExcel(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/fragment-pages", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.FragmentPage
		if !decodeFragment(w, r, &in) {
			return
		}
		v, e := s.ImportFragmentPage(r.Context(), in)
		reply(w, map[string]string{"kind": v}, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/fragment", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.ExportFragment(r.Context(), r.PathValue("kind"), year(r), r.URL.Query().Get("range"))
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/fragment-preview", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.FragmentImport
		if !decodeFragment(w, r, &in) {
			return
		}
		v, e := s.PreviewFragment(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/fragment-import", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.FragmentImport
		if !decodeFragment(w, r, &in) {
			return
		}
		v, e := s.ApplyFragment(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/history-catalog", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.HistoryCatalog(r.Context(), r.URL.Query().Get("screen"), r.URL.Query().Get("station"))
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/history-preview", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.HistoryBinding
		if !decode(w, r, &in) {
			return
		}
		v, e := s.PreviewHistory(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/history-binding", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.HistoryBindingChange
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveHistoryBinding(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/history-refresh", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.RefreshHistory(r.Context(), r.PathValue("kind"), year(r))
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/pages", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.PageImport
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 13*1024*1024))
		decoder.DisallowUnknownFields()
		if e := decoder.Decode(&in); e != nil {
			reply(w, nil, fmt.Errorf("Excel上传内容无效或过大"))
			return
		}
		kind, e := s.ImportPage(r.Context(), in)
		reply(w, map[string]string{"kind": kind}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/templates/{kind}/original", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.WorkbookUpload
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 13*1024*1024))
		decoder.DisallowUnknownFields()
		if e := decoder.Decode(&in); e != nil {
			reply(w, nil, fmt.Errorf("Excel原稿无效或过大"))
			return
		}
		e := s.AttachOriginal(r.Context(), r.PathValue("kind"), in)
		reply(w, map[string]bool{"saved": e == nil}, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Catalog(r.Context())
		canConfigure := true
		if a, ok := authorization.FromContext(r.Context()); ok {
			canConfigure = a.Active() && !a.ReadOnly && a.Grants.Develop()
		}
		reply(w, map[string]any{"items": v, "can_configure": canConfigure}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/templates", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.Template
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 13*1024*1024))
		decoder.DisallowUnknownFields()
		if e := decoder.Decode(&in); e != nil {
			reply(w, nil, fmt.Errorf("报表模板无效或过大"))
			return
		}
		e := s.SaveTemplate(r.Context(), in)
		reply(w, map[string]bool{"saved": e == nil}, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Document(r.Context(), r.PathValue("kind"), year(r))
		if e != nil {
			reply(w, nil, e)
			return
		}
		reply(w, map[string]any{"document": v, "sheet": v.Sheet()}, nil)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/changes", func(w http.ResponseWriter, r *http.Request) {
		after, e := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
		if e != nil {
			reply(w, nil, e)
			return
		}
		v, e := s.Changes(r.Context(), r.PathValue("kind"), year(r), after)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/changes", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.Patch
		if !decode(w, r, &in) {
			return
		}
		v, e := s.Patch(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/locks", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Leases(r.Context(), r.PathValue("kind"), year(r))
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/locks", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.LeaseRequest
		if !decode(w, r, &in) {
			return
		}
		v, e := s.Acquire(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/checkpoints", func(w http.ResponseWriter, r *http.Request) {
		before := int64(0)
		var e error
		if r.URL.Query().Get("before") != "" {
			before, e = strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
		}
		if e != nil || before < 0 {
			reply(w, nil, fmt.Errorf("分页参数无效"))
			return
		}
		v, e := s.Checkpoints(r.Context(), r.PathValue("kind"), year(r), before)
		reply(w, map[string]any{"items": v}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/checkpoints", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Expected int64 `json:"expected"`
		}
		if !decode(w, r, &in) {
			return
		}
		v, e := s.CreateCheckpoint(r.Context(), r.PathValue("kind"), year(r), in.Expected)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/rollback", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.Rollback
		if !decode(w, r, &in) {
			return
		}
		v, e := s.Rollback(r.Context(), r.PathValue("kind"), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/export", func(w http.ResponseWriter, r *http.Request) {
		b, e := s.Export(r.Context(), r.PathValue("kind"), year(r))
		reply(w, map[string]string{"data": base64.StdEncoding.EncodeToString(b), "name": fmt.Sprintf("%s-%d.xlsx", r.PathValue("kind"), year(r))}, e)
	})
	guarded := originGuard(permissionGuard(mux), origin)
	mux.HandleFunc("GET /api/v1/total-reports/heat-bindings", func(w http.ResponseWriter, r *http.Request) {
		settings, e := s.HeatSettings(r.Context())
		if e != nil {
			reply(w, nil, e)
			return
		}
		sources, e := s.HeatSources(r.Context())
		reply(w, map[string]any{"settings": settings, "sources": sources}, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/heat-bindings", func(w http.ResponseWriter, r *http.Request) {
		var in totalreports.HeatSettings
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveHeatSettings(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/total-reports/{kind}/{year}/heat-sync", func(w http.ResponseWriter, r *http.Request) {
		if r.PathValue("kind") != "heat" {
			reply(w, nil, fmt.Errorf("只有热表可同步后台表底"))
			return
		}
		var in totalreports.HeatSync
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SyncHeat(r.Context(), year(r), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/total-reports/{kind}/{year}/heat-readings", func(w http.ResponseWriter, r *http.Request) {
		if r.PathValue("kind") != "heat" {
			reply(w, nil, fmt.Errorf("只有热表有后台表底"))
			return
		}
		v, e := s.HeatReadings(r.Context(), year(r))
		reply(w, map[string]any{"items": v}, e)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/total-reports" || strings.HasPrefix(r.URL.Path, "/api/v1/total-reports/") {
			guarded.ServeHTTP(w, r)
		} else {
			next.ServeHTTP(w, r)
		}
	})
}
