package server

import (
	"errors"
	"net"
	"net/http"
	"net/netip"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

func publicBansAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, actor authorization.Actor, session identity.Session) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	localAdmin := err == nil && IsLoopbackHost(host) && session.Channel == "" && actor.Grants.Manage()
	if !actor.Active() || !actor.Grants.ManagePublicBans() || (r.URL.Path == "/api/v1/security/public-bans/ban" && !localAdmin) {
		writeError(w, 403, "permission_denied", "需要封禁查看与解封权限；手动封禁仅限本机管理员")
		return
	}
	if (r.URL.Path == "/api/v1/security/public-bans/unban" || r.URL.Path == "/api/v1/security/public-bans/ban") && r.Method == "POST" {
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		var in struct {
			Revision int64  `json:"revision"`
			IP       string `json:"ip"`
			Minutes  int64  `json:"minutes"`
		}
		if !decode(w, r, &in) {
			return
		}
		ip, e := netip.ParseAddr(in.IP)
		if e != nil || ip.Zone() != "" || in.Minutes < 0 || in.Minutes > 365*24*60 {
			writeError(w, 400, "invalid_request", "请输入有效的 IP 与封禁时长")
			return
		}
		if r.URL.Path == "/api/v1/security/public-bans/ban" {
			if in.Minutes < 1 {
				writeError(w, 400, "invalid_request", "封禁至少持续 1 分钟")
				return
			}
			err = s.ManuallyBanPublicPeer(actor, in.Revision, ip.Unmap().String(), time.Duration(in.Minutes)*time.Minute)
		} else {
			err = s.UnbanPublicPeer(actor, in.Revision, ip.Unmap().String())
		}
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
	writeError(w, 503, "public_guard_unavailable", "封禁状态不可用；未放行网络访问")
}
