package server

import (
	"errors"
	"net"
	"net/http"
	"strconv"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func publicAccessEventsAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, actor authorization.Actor, session identity.Session) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !IsLoopbackHost(host) || session.Channel != "" || !actor.Active() || !actor.Grants.Manage() {
		writeError(w, 403, "permission_denied", "仅本机管理员可查看公网请求记录")
		return
	}
	if r.Method != "GET" {
		w.Header().Set("Allow", "GET")
		writeError(w, 405, "method_not_allowed", "请求记录仅支持读取")
		return
	}
	var before int64
	limit := 100
	if raw := r.URL.Query().Get("before"); raw != "" {
		before, err = strconv.ParseInt(raw, 10, 64)
		if err != nil || before < 0 {
			writeError(w, 400, "invalid_request", "无效的记录游标")
			return
		}
	}
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 200 {
			writeError(w, 400, "invalid_request", "每页记录数须为1至200")
			return
		}
	}
	result, err := s.PublicAccessEvents(actor, before, limit)
	if errors.Is(err, identity.ErrPublicAccessAuditUnavailable) {
		writeError(w, 503, "audit_unavailable", "公网请求记录不可用，不能视为没有访问记录")
		return
	}
	outcome(w, result, err)
}
