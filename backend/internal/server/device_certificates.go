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

func deviceCertificatesAPI(w http.ResponseWriter, r *http.Request, s *identity.Service, actor authorization.Actor, session identity.Session) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !IsLoopbackHost(host) || session.Channel != "" || !actor.Active() || !actor.Grants.Manage() {
		writeError(w, 403, "permission_denied", "仅本机管理员可管理设备证书审批")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/security/device-certificates")
	var snapshot identity.DeviceCertificateSnapshot
	if path == "" {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			writeError(w, 405, "method_not_allowed", "只支持读取")
			return
		}
		snapshot, err = s.DeviceCertificates(actor)
	} else {
		parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
		if len(parts) != 2 || parts[0] == "" || (parts[1] != "approve" && parts[1] != "revoke") {
			writeError(w, 404, "not_found", "证书审批操作不存在")
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			writeError(w, 405, "method_not_allowed", "只支持 POST")
			return
		}
		if parts[1] == "approve" {
			r.Body = http.MaxBytesReader(w, r.Body, 24576)
			var in struct {
				Revision  int64     `json:"revision"`
				LeafPEM   string    `json:"leaf_pem"`
				ExpiresAt time.Time `json:"expires_at"`
			}
			if !decode(w, r, &in) {
				return
			}
			snapshot, err = s.ApproveDeviceCertificate(actor, in.Revision, parts[0], in.LeafPEM, in.ExpiresAt)
		} else {
			r.Body = http.MaxBytesReader(w, r.Body, 1024)
			var in struct {
				Revision int64 `json:"revision"`
			}
			if !decode(w, r, &in) {
				return
			}
			snapshot, err = s.RevokeDeviceCertificate(actor, in.Revision, parts[0])
		}
	}
	switch {
	case errors.Is(err, identity.ErrDeviceCertificateConflict):
		writeError(w, 409, "device_certificate_conflict", "证书审批或设备登记已改变，请保留输入并刷新核对")
	case errors.Is(err, identity.ErrDeviceCertificateUnavailable), errors.Is(err, identity.ErrDeviceRegistrationUnavailable):
		writeError(w, 503, "device_certificate_unavailable", "证书审批存储不可用；不会显示为空或退回其他授权")
	case errors.Is(err, identity.ErrDeviceCertificateInvalid):
		writeError(w, 422, "invalid_device_certificate", "请检查登记、公钥、叶证书用途、有效期和归属账号")
	case errors.Is(err, identity.ErrDeviceCertificateNotFound):
		writeError(w, 404, "device_certificate_not_found", "设备登记或证书审批不存在")
	default:
		outcome(w, snapshot, err)
	}
}
