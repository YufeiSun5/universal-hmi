package server

import (
	"errors"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

// These are local inventory records, not a mobile authentication channel.
// The independent guard remains necessary even if route mounting changes later.
func deviceRegistrationsAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, actor authorization.Actor, session identity.Session) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !IsLoopbackHost(host) || session.Channel != "" || !actor.Active() || !actor.Grants.Manage() {
		writeError(w, 403, "permission_denied", "仅本机管理员可管理设备登记")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/security/devices")
	var snapshot identity.DeviceRegistrationSnapshot
	if path == "" {
		switch r.Method {
		case http.MethodGet:
			snapshot, err = s.DeviceRegistrations(actor)
		case http.MethodPost:
			r.Body = http.MaxBytesReader(w, r.Body, 16384)
			var in struct {
				Revision    int64  `json:"revision"`
				OwnerUserID string `json:"owner_user_id"`
				Label       string `json:"label"`
				CSRPEM      string `json:"csr_pem"`
			}
			if !decode(w, r, &in) {
				return
			}
			snapshot, err = s.CreateDeviceRegistration(actor, in.Revision, in.OwnerUserID, in.Label, in.CSRPEM)
		default:
			w.Header().Set("Allow", "GET, POST")
			writeError(w, 405, "method_not_allowed", "只支持读取或新建设备登记")
			return
		}
	} else {
		parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
		if len(parts) != 2 || parts[0] == "" || (parts[1] != "approve" && parts[1] != "disable" && parts[1] != "approve-login") {
			writeError(w, 404, "not_found", "设备登记操作不存在")
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			writeError(w, 405, "method_not_allowed", "设备登记审批和禁用只支持 POST")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		if parts[1] == "approve" {
			var in struct {
				Revision  int64     `json:"revision"`
				ExpiresAt time.Time `json:"expires_at"`
			}
			if !decode(w, r, &in) {
				return
			}
			snapshot, err = s.ApproveDeviceRegistration(actor, in.Revision, parts[0], in.ExpiresAt)
		} else if parts[1] == "approve-login" {
			var in struct {
				Revision int64 `json:"revision"`
			}
			if !decode(w, r, &in) {
				return
			}
			snapshot, err = s.ApproveLoginDevice(actor, in.Revision, parts[0])
		} else {
			var in struct {
				Revision int64 `json:"revision"`
			}
			if !decode(w, r, &in) {
				return
			}
			snapshot, err = s.DisableDeviceRegistration(actor, in.Revision, parts[0])
		}
	}
	switch {
	case errors.Is(err, identity.ErrDeviceRegistrationConflict):
		writeError(w, 409, "device_registration_conflict", "设备登记已被修改，请保留输入并刷新后核对")
	case errors.Is(err, identity.ErrDeviceRegistrationUnavailable):
		writeError(w, 503, "device_registration_unavailable", "设备登记存储不可用；不会显示为空或改变现有公网策略")
	case errors.Is(err, identity.ErrDeviceRegistrationInvalid):
		writeError(w, 422, "invalid_device_registration", "请检查归属账号、名称、P-256 签名请求、有效期或重复公钥")
	case errors.Is(err, identity.ErrDeviceRegistrationNotFound):
		writeError(w, 404, "device_registration_not_found", "设备登记不存在")
	default:
		outcome(w, snapshot, err)
	}
}
