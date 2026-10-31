package server

import (
	"errors"
	"net"
	"net/http"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

// Management is restricted independently of the public route allowlist.
func publicIPPolicyAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, actor authorization.Actor, session identity.Session) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !IsLoopbackHost(host) || session.Channel != "" || !actor.Active() || !actor.Grants.Manage() {
		writeError(w, 403, "permission_denied", "仅本机管理员可管理公网白名单")
		return
	}
	var policy identity.PublicIPPolicy
	switch r.Method {
	case "GET":
		policy, err = s.PublicIPPolicy(actor)
	case "PUT":
		var in struct {
			Revision int64                   `json:"revision"`
			Rules    []identity.PublicIPRule `json:"rules"`
		}
		if !decode(w, r, &in) {
			return
		}
		policy, err = s.SavePublicIPPolicy(actor, in.Revision, in.Rules)
	default:
		w.Header().Set("Allow", "GET, PUT")
		writeError(w, 405, "method_not_allowed", "只支持读取或保存白名单")
		return
	}
	switch {
	case errors.Is(err, identity.ErrPublicIPConflict):
		writeError(w, 409, "policy_conflict", "白名单已被其他管理员修改，请保留草稿并重新载入后核对")
	case errors.Is(err, identity.ErrPublicIPUnavailable):
		writeError(w, 503, "policy_unavailable", "公网策略存储不可用，请在本机修复后重启；不会退回文件规则")
	case errors.Is(err, identity.ErrPublicIPInvalid):
		writeError(w, 422, "invalid_policy", "请检查 IP/CIDR、归属、有效期和规则数量")
	default:
		outcome(w, policy, err)
	}
}
