package server

import (
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"net/http"
	"strings"
)

// The default for new API operations is engineering permission. New runtime
// operations must be deliberately classified and implement their data scope.
func permissionGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/") {
			next.ServeHTTP(w, r)
			return
		}
		a, managed := authorization.FromContext(r.Context())
		p, authenticated := PrincipalFromContext(r.Context())
		if !managed && (!authenticated || p.Local) {
			next.ServeHTTP(w, r)
			return
		}
		if managed && !a.Active() {
			writeError(w, 401, "authentication_required", "登录状态已失效")
			return
		}
		path := r.URL.Path
		read := r.Method == "GET" || r.Method == "HEAD"
		allowed := false
		switch {
		case read && (path == "/api/v1/equipment-navigation" || path == "/api/v1/equipment" || strings.HasPrefix(path, "/api/v1/equipment/")):
			allowed = true
		case path == "/api/v1/external/screens" && read || strings.HasPrefix(path, "/api/v1/external/screens/") && (read || strings.HasSuffix(path, "/query") && r.Method == "POST"):
			// The external-data service checks its independent screen grants.
			allowed = true
		case read && (path == "/api/v1/stations" || path == "/api/v1/points" || path == "/api/v1/runtime" || path == "/api/v1/runtime/events" || path == "/api/v1/history" || path == "/api/v1/history/catalog" || path == "/api/v1/screens" || strings.HasPrefix(path, "/api/v1/screens/") || path == "/api/v1/navigation" || path == "/api/v1/jobs" || strings.HasPrefix(path, "/api/v1/jobs/")):
			allowed = true
		case path == "/api/v1/export" || strings.HasPrefix(path, "/api/v1/import/") || strings.HasPrefix(path, "/api/v1/jobs/"):
			allowed = managed && a.Grants.Export
		case path == "/api/v1/write" || strings.HasPrefix(path, "/api/v1/commands/") || strings.HasSuffix(path, "/write-capability"):
			allowed = managed && a.Grants.Control
		case read && path == "/api/v1/executions":
			allowed = managed && a.Grants.Has("auditor") && a.Grants.AllStations
		default:
			allowed = managed && a.Grants.Develop() || !managed && p.Engineer
		}
		if !allowed {
			if managed && a.Audit != nil {
				_ = a.Audit("access", r.Method+" "+path, "denied")
			}
			writeError(w, 403, "permission_denied", "当前账号没有此操作权限")
			return
		}
		if managed && !read && a.Audit != nil {
			if err := a.Audit("operation", r.Method+" "+path, "authorized intent"); err != nil {
				writeError(w, 503, "audit_unavailable", "审计记录不可用，操作未执行")
				return
			}
			recorded := &operationResponse{ResponseWriter: w, status: 200}
			next.ServeHTTP(recorded, r)
			_ = a.Audit("operation.result", r.Method+" "+path, fmt.Sprintf("HTTP %d; policy version %d", recorded.status, a.Version))
			return
		}
		next.ServeHTTP(w, r)
	})
}

type operationResponse struct {
	http.ResponseWriter
	status int
}

func (w *operationResponse) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}
