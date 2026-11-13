package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/materials"
)

// Explicitly shared by the authenticated handler and remote route boundary.
// Unknown operations do not become allowed by introducing this module.
func materialsRoutes() []string {
	return []string{
		"GET /api/v1/materials/capabilities",
		"GET /api/v1/materials/categories", "POST /api/v1/materials/categories",
		"GET /api/v1/materials/items", "POST /api/v1/materials/items", "GET /api/v1/materials/items/{id}",
		"GET /api/v1/materials/applications", "POST /api/v1/materials/applications", "GET /api/v1/materials/applications/{id}", "POST /api/v1/materials/applications/{id}/decision",
		"GET /api/v1/materials/inbound", "POST /api/v1/materials/inbound",
		"GET /api/v1/materials/outbound", "POST /api/v1/materials/outbound", "POST /api/v1/materials/outbound-preview",
		"GET /api/v1/materials/return", "POST /api/v1/materials/return",
		"GET /api/v1/materials/transfer", "POST /api/v1/materials/transfer",
		"GET /api/v1/materials/stock", "GET /api/v1/materials/movements",
		"GET /api/v1/materials/chains", "GET /api/v1/materials/chains/{kind}/{id}",
		"GET /api/v1/materials/documents/{id}", "GET /api/v1/materials/documents/{id}/export",
		"POST /api/v1/materials/assets", "GET /api/v1/materials/assets/{id}",
		"GET /api/v1/account/signature", "POST /api/v1/account/signature",
		"GET /api/v1/account/signature/history",
	}
}
func materialsPath(path string) bool {
	return strings.HasPrefix(path, "/api/v1/materials/") || path == "/api/v1/account/signature" || path == "/api/v1/account/signature/history"
}

func MaterialsHandler(next http.Handler, s *materials.Service, origin string) http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any, e error) {
		switch {
		case errors.Is(e, materials.ErrMissing):
			writeError(w, 404, "not_found", e.Error())
		case errors.Is(e, materials.ErrConflict):
			writeError(w, 409, "revision_conflict", e.Error())
		case errors.Is(e, materials.ErrStock):
			writeError(w, 409, "stock_conflict", e.Error())
		case errors.Is(e, materials.ErrSignature):
			writeError(w, 422, "signature_required", e.Error())
		default:
			outcome(w, v, e)
		}
	}
	filters := func(w http.ResponseWriter, r *http.Request) (materials.Filter, bool) {
		q := r.URL.Query()
		f := materials.Filter{Search: q.Get("search"), Status: q.Get("status"), ItemID: q.Get("item_id"), CategoryID: q.Get("category_id"), OwnerID: q.Get("owner_id"), From: q.Get("from"), To: q.Get("to"), Kind: q.Get("kind")}
		if q.Has("parent_id") {
			parent := q.Get("parent_id")
			f.ParentID = &parent
		}
		for key, p := range map[string]*int{"offset": &f.Offset, "limit": &f.Limit} {
			if q.Get(key) != "" {
				v, e := strconv.Atoi(q.Get(key))
				if e != nil {
					writeError(w, 400, "invalid_request", "分页参数无效")
					return f, false
				}
				*p = v
			}
		}
		return f, true
	}
	mux.HandleFunc("GET /api/v1/materials/capabilities", func(w http.ResponseWriter, r *http.Request) {
		a, ok := authorization.FromContext(r.Context())
		if !ok || !a.Active() {
			outcome(w, nil, authorization.ErrDenied)
			return
		}
		reply(w, map[string]any{"user_id": a.ID, "username": a.DisplayName, "grants": a.Grants}, nil)
	})
	mux.HandleFunc("GET /api/v1/materials/chains", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Chains(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/chains/{kind}/{id}", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Chain(r.Context(), r.PathValue("kind"), r.PathValue("id"), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/categories", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Categories(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/materials/categories", func(w http.ResponseWriter, r *http.Request) {
		var in materials.CategoryInput
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveCategory(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/items", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Items(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/items/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.Item(r.Context(), r.PathValue("id"))
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/materials/items", func(w http.ResponseWriter, r *http.Request) {
		var in materials.ItemInput
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveItem(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/applications", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Applications(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/applications/{id}", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Application(r.Context(), r.PathValue("id"), f)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/materials/applications", func(w http.ResponseWriter, r *http.Request) {
		var in materials.ApplicationInput
		if !decode(w, r, &in) {
			return
		}
		v, e := s.Submit(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/materials/applications/{id}/decision", func(w http.ResponseWriter, r *http.Request) {
		var in materials.ApprovalInput
		if !decode(w, r, &in) {
			return
		}
		v, e := s.Approve(r.Context(), r.PathValue("id"), in)
		reply(w, v, e)
	})
	for _, kind := range []string{"inbound", "outbound", "return", "transfer"} {
		mux.HandleFunc("GET /api/v1/materials/"+kind, func(w http.ResponseWriter, r *http.Request) {
			f, ok := filters(w, r)
			if !ok {
				return
			}
			v, e := s.Documents(r.Context(), kind, f)
			reply(w, v, e)
		})
		mux.HandleFunc("POST /api/v1/materials/"+kind, func(w http.ResponseWriter, r *http.Request) {
			var in materials.DocumentInput
			if !decode(w, r, &in) {
				return
			}
			v, e := s.Confirm(r.Context(), kind, in)
			reply(w, v, e)
		})
	}
	mux.HandleFunc("POST /api/v1/materials/outbound-preview", func(w http.ResponseWriter, r *http.Request) {
		var in materials.DocumentInput
		if !decode(w, r, &in) {
			return
		}
		v, e := s.PreviewOutbound(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/stock", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Stock(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/movements", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Movements(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/documents/{id}", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.Document(r.Context(), r.PathValue("id"), f)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/documents/{id}/export", func(w http.ResponseWriter, r *http.Request) {
		data, name, e := s.Export(r.Context(), r.PathValue("id"))
		if e != nil {
			reply(w, nil, e)
			return
		}
		if r.URL.Query().Get("encoding") == "base64" {
			reply(w, map[string]any{"name": name, "data": data}, nil)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
		w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
		_, _ = w.Write(data)
	})
	mux.HandleFunc("GET /api/v1/account/signature", func(w http.ResponseWriter, r *http.Request) { v, e := s.Signature(r.Context()); reply(w, v, e) })
	mux.HandleFunc("GET /api/v1/account/signature/history", func(w http.ResponseWriter, r *http.Request) {
		f, ok := filters(w, r)
		if !ok {
			return
		}
		v, e := s.SignatureHistory(r.Context(), f)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/account/signature", func(w http.ResponseWriter, r *http.Request) {
		var in materials.SignatureInput
		if !decode(w, r, &in) {
			return
		}
		v, e := s.SaveSignature(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("POST /api/v1/materials/assets", func(w http.ResponseWriter, r *http.Request) {
		var in materials.AssetInput
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 14*1024*1024))
		dec.DisallowUnknownFields()
		if e := dec.Decode(&in); e != nil {
			writeError(w, 400, "invalid_image", "图片请求无效或超过10 MiB")
			return
		}
		if dec.Decode(new(any)) != io.EOF {
			writeError(w, 400, "invalid_request", "请求格式无效")
			return
		}
		v, e := s.Upload(r.Context(), in)
		reply(w, v, e)
	})
	mux.HandleFunc("GET /api/v1/materials/assets/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, data, e := s.Asset(r.Context(), r.PathValue("id"))
		reply(w, map[string]any{"asset": v, "data": data}, e)
	})
	guarded := originGuard(permissionGuard(mux), origin)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if materialsPath(r.URL.Path) {
			w.Header().Set("Cache-Control", "no-store")
			guarded.ServeHTTP(w, r)
		} else {
			next.ServeHTTP(w, r)
		}
	})
}
