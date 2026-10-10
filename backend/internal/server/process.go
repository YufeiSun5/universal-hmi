package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"regexp"
	"strconv"

	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
)

var unknownScreenField = regexp.MustCompile(`^json: unknown field "([a-zA-Z0-9_]{1,64})"$`)

// Do not expose raw request contents; distinguish size, version and field type
// failures so a small valid-looking drawing is not described as oversized.
func screenDecodeMessage(err error) string {
	var size *http.MaxBytesError
	var field *json.UnmarshalTypeError
	var syntax *json.SyntaxError
	switch {
	case errors.As(err, &size):
		return "工艺画面文件超过 8 MiB，请减少嵌入图片或拆分画面"
	case errors.As(err, &field):
		if field.Type.Kind() == reflect.Int || field.Type.Kind() == reflect.Int64 {
			return "画面字段 " + field.Field + " 必须为整数，请检查数量、小数位数或版本"
		}
		return "画面字段 " + field.Field + " 的数据类型不正确"
	case errors.As(err, &syntax):
		return "工艺画面 JSON 格式错误（位置 " + strconv.FormatInt(syntax.Offset, 10) + "）"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "工艺画面文件为空或内容不完整"
	default:
		if match := unknownScreenField.FindStringSubmatch(err.Error()); match != nil {
			return "画面包含当前服务不支持的字段 " + match[1] + "，请更新服务后重试"
		}
		return "工艺画面文件格式无效"
	}
}

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
			writeError(w, 400, "invalid_request", screenDecodeMessage(err))
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF {
			message := "工艺画面只能包含一个 JSON 对象"
			if err != nil {
				message = screenDecodeMessage(err)
			}
			writeError(w, 400, "invalid_request", message)
			return
		}
		if d.ID != r.PathValue("id") {
			writeError(w, 400, "invalid_request", "画面身份与保存地址不匹配")
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
