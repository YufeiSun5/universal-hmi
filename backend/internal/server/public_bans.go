package server

import (
	"errors"
	"net"
	"net/http"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func publicBansAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, actor authorization.Actor, session identity.Session) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !IsLoopbackHost(host) || session.Channel != "" || !actor.Active() || !actor.Grants.Manage() {
		writeError(w, 403, "permission_denied", "仅本机管理员可查看封禁和解封")
		return
	}
	if r.URL.Path == "/api/v1/security/public-bans/unban" && r.Method == "POST" {
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		var in struct {
			Revision int64  `json:"revision"`
			IP       string `json:"ip"`
		}
		if !decode(w, r, &in) {
			return
		}
		err = s.UnbanPublicPeer(actor, in.Revision, in.IP)
	} else if r.URL.Path != "/api/v1/security/public-bans" || r.Method != "GET" {
		writeError(w, 405, "method_not_allowed", "仅支持读取和明确解封操作")
		return
	}
	if errors.Is(err, identity.ErrPublicBanConflict) {
		writeError(w, 409, "public_ban_conflict", "封禁列表已改变，请刷新核对")
		return
	}
	if err == nil {
		var result identity.PublicBanSnapshot
		result, err = s.PublicBans(actor)
		if err == nil {
			writeJSON(w, 200, result)
			return
		}
	}
	if errors.Is(err, identity.ErrDenied) {
		writeError(w, 403, "permission_denied", "没有管理权限")
		return
	}
	writeError(w, 503, "public_guard_unavailable", "封禁状态不可用；未放行公网访问")
}
