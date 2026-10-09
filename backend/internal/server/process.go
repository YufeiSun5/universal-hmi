package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

func screenOutcome(w http.ResponseWriter, data any, err error) {
	if err == nil {
		writeJSON(w, 200, data)
		return
	}
	switch {
	case errors.Is(err, process.ErrConflict):
		writeError(w, 409, "screen_conflict", "画面已由其他窗口修改，请另存副本或重新打开")
	case errors.Is(err, process.ErrNotFound):
		writeError(w, 404, "screen_not_found", "工艺画面不存在")
	case errors.Is(err, process.ErrInvalid):
		writeError(w, 422, "invalid_screen", err.Error())
	default:
		writeError(w, 500, "screen_save_failed", "工艺画面操作失败，未确认保存")
	}
}

func registerScreens(mux *http.ServeMux, screens *process.Service) {
	registerMaterials(mux, screens)
	mux.HandleFunc("GET /api/v1/screens", func(w http.ResponseWriter, r *http.Request) {
		items, err := screens.List(r.URL.Query().Get("station"))
		screenOutcome(w, map[string]any{"items": items}, err)
	})
	mux.HandleFunc("GET /api/v1/screens/{id}", func(w http.ResponseWriter, r *http.Request) {
		d, err := screens.Get(r.PathValue("id"))
		screenOutcome(w, d, err)
	})
	mux.HandleFunc("PUT /api/v1/screens/{id}", func(w http.ResponseWriter, r *http.Request) {
		var d process.Document
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, process.MaxDocumentBytes))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&d); err != nil {
			writeError(w, 400, "invalid_request", "无效或过大的工艺画面文件")
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF || d.ID != r.PathValue("id") {
			writeError(w, 400, "invalid_request", "画面身份不匹配或包含多个 JSON 对象")
			return
		}
		saved, err := screens.Save(d)
		screenOutcome(w, saved, err)
	})
	mux.HandleFunc("DELETE /api/v1/screens/{id}", func(w http.ResponseWriter, r *http.Request) {
		revision, err := strconv.ParseInt(r.URL.Query().Get("revision"), 10, 64)
		if err != nil || revision < 1 {
			writeError(w, 400, "revision_required", "删除画面需要当前版本")
			return
		}
		err = screens.Delete(r.PathValue("id"), revision)
		screenOutcome(w, map[string]bool{"deleted": err == nil}, err)
	})
}

func materialOutcome(w http.ResponseWriter, data any, err error) {
	if err == nil {
		writeJSON(w, 200, data)
		return
	}
	switch {
	case errors.Is(err, process.ErrConflict):
		writeError(w, 409, "material_conflict", "素材版本已变化，请刷新素材库")
	case errors.Is(err, process.ErrNotFound):
		writeError(w, 404, "material_not_found", "素材不存在，请刷新素材库")
	case errors.Is(err, process.ErrInvalid):
		writeError(w, 422, "invalid_material", err.Error())
	default:
		writeError(w, 500, "material_operation_failed", "素材操作失败，未确认保存")
	}
}

func registerMaterials(mux *http.ServeMux, screens *process.Service) {
	mux.HandleFunc("GET /api/v1/process-materials", func(w http.ResponseWriter, r *http.Request) {
		items, err := screens.ListMaterials()
		materialOutcome(w, map[string]any{"items": items}, err)
	})
	mux.HandleFunc("GET /api/v1/process-materials/{id}", func(w http.ResponseWriter, r *http.Request) {
		m, err := screens.GetMaterial(r.PathValue("id"))
		materialOutcome(w, m, err)
	})
	mux.HandleFunc("PUT /api/v1/process-materials/{id}", func(w http.ResponseWriter, r *http.Request) {
		var m process.Material
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, process.MaxMaterialBytes))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&m); err != nil {
			writeError(w, 400, "invalid_request", "无效或过大的素材文件")
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF || m.ID != r.PathValue("id") {
			writeError(w, 400, "invalid_request", "素材身份不匹配或包含多个 JSON 对象")
			return
		}
		saved, err := screens.SaveMaterial(m)
		materialOutcome(w, saved, err)
	})
	mux.HandleFunc("DELETE /api/v1/process-materials/{id}", func(w http.ResponseWriter, r *http.Request) {
		revision, err := strconv.ParseInt(r.URL.Query().Get("revision"), 10, 64)
		if err != nil || revision < 1 {
			writeError(w, 400, "revision_required", "删除素材需要当前版本")
			return
		}
		err = screens.DeleteMaterial(r.PathValue("id"), revision)
		materialOutcome(w, map[string]bool{"deleted": err == nil}, err)
	})
}
