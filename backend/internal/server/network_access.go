package server

import (
	"errors"
	"fmt"
	"net"
	"net/http"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/networkaccess"
)

func networkAccessAPI(w http.ResponseWriter, r *http.Request, s *networkaccess.Service, identities *identity.Service, a authorization.Actor, session identity.Session, local bool) {
	host, _, e := net.SplitHostPort(r.RemoteAddr)
	if !local || e != nil || !IsLoopbackHost(host) || session.Channel != "" || !a.Active() || !a.Grants.Manage() {
		writeError(w, 403, "permission_denied", "网络入口仅允许本机管理员配置")
		return
	}
	if s == nil {
		writeError(w, 503, "network_access_unavailable", "当前服务没有网络入口配置能力")
		return
	}
	if r.Method == "GET" {
		v, e := s.Snapshot()
		outcome(w, v, e)
		return
	}
	if r.Method != "PUT" && r.Method != "POST" {
		w.Header().Set("Allow", "GET, PUT, POST")
		writeError(w, 405, "method_not_allowed", "仅支持读取、保存和应用")
		return
	}
	if r.Method == "POST" {
		var request struct {
			Revision int64  `json:"revision"`
			Action   string `json:"action,omitempty"`
		}
		if !decode(w, r, &request) {
			return
		}
		if request.Action == "authorize_restart" || request.Action == "authorize_startup" {
			action := "backend.restart"
			if request.Action == "authorize_startup" {
				action = "backend.startup.configure"
			}
			if err := identities.Record(a.ID, action, "local project", "authorized_client_request"); err != nil {
				writeError(w, 503, "audit_unavailable", "审计存储不可用，未授权本机后台配置")
				return
			}
			outcome(w, map[string]bool{"authorized": true}, nil)
			return
		}
		if request.Action != "" {
			writeError(w, 422, "invalid_network_action", "未知的网络入口操作")
			return
		}
		if err := identities.Record(a.ID, "lan_access.apply", fmt.Sprint(request.Revision), "attempt"); err != nil {
			writeError(w, 503, "audit_unavailable", "审计存储不可用，未应用入口配置")
			return
		}
		v, err := s.Apply(request.Revision)
		switch {
		case errors.Is(err, networkaccess.ErrBusy):
			writeError(w, 409, "network_access_busy", "另一项网络操作正在执行，请稍后刷新")
		case errors.Is(err, networkaccess.ErrConflict):
			writeError(w, 409, "network_access_conflict", "配置已改变，请重新读取后应用")
		default:
			if err == nil {
				if auditErr := identities.Record(a.ID, "lan_access.apply", v.RunningOrigin, v.Phase); auditErr != nil {
					v.StatusError += "；完成审计写入失败，请检查审计存储"
				}
			}
			outcome(w, v, err)
		}
		return
	}
	var in networkaccess.Input
	if !decode(w, r, &in) {
		return
	}
	target := fmt.Sprintf("%s:%d enabled=%t allow_development=%t", in.Address, in.Port, in.Enabled, in.AllowDevelopment)
	if e = identities.Record(a.ID, "lan_access.configure", target, "attempt"); e != nil {
		writeError(w, 503, "audit_unavailable", "审计存储不可用，未保存入口配置")
		return
	}
	v, e := s.Save(in)
	if e == nil {
		if auditErr := identities.Record(a.ID, "lan_access.configure", target, "saved_pending_apply"); auditErr != nil {
			v.StatusError = "配置已保存，但完成审计写入失败，请检查审计存储"
		}
	}
	switch {
	case errors.Is(e, networkaccess.ErrConflict):
		writeError(w, 409, "network_access_conflict", "配置已改变，请保留草稿并重新加载核对")
	case errors.Is(e, networkaccess.ErrInvalid):
		writeError(w, 422, "invalid_network_access", "请选择本机内网 IPv4，端口范围为1024–65535")
	default:
		outcome(w, v, e)
	}
}

// An optional LAN endpoint still passes the shared IP, login and read-only gates.
// Its additional private-peer gate never trusts forwarded headers.
func LANPeerHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, e := net.SplitHostPort(r.RemoteAddr)
		if e != nil || !networkaccess.IsPrivateIPv4(host) {
			identityReject(w, r, 403, "public_peer_denied", "此入口仅接受内网客户端")
			return
		}
		next.ServeHTTP(w, r)
	})
}
