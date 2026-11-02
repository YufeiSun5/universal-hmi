package server

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

type publicAuditKey struct{}
type publicAuditState struct {
	userID, decision string
	channel          string
	approval         PublicIPApproval
	valid            func() bool
}

func publicAuditStateFor(r *http.Request) *publicAuditState {
	s, _ := r.Context().Value(publicAuditKey{}).(*publicAuditState)
	return s
}
func publicAuditUser(r *http.Request, id string) {
	if s := publicAuditStateFor(r); s != nil {
		s.userID = id
	}
}
func publicAuditReason(r *http.Request, code string) {
	s := publicAuditStateFor(r)
	if s == nil {
		return
	}
	switch code {
	case "login_failed":
		s.decision = "authentication_failed"
	case "authentication_required":
		s.decision = "authentication_required"
	case "public_ip_denied", "public_device_denied", "public_read_only", "public_path_denied":
		s.decision = code
	case "public_peer_denied", "public_guard_unavailable", "public_peer_banned", "public_rate_limited", "public_waf_denied":
		s.decision = code
	}
}

// PublicAccessAuditHandler observes only the public listener. It records fixed
// route categories, never URLs, query strings, bodies, credentials or headers.
func PublicAccessAuditHandler(next http.Handler, service *identity.Service) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		state := &publicAuditState{channel: "public:web"}
		r = r.WithContext(context.WithValue(r.Context(), publicAuditKey{}, state))
		peer := ""
		if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
			if ip, err := netip.ParseAddr(host); err == nil && ip.Zone() == "" {
				peer = ip.Unmap().String()
			}
		}
		method := r.Method
		switch method {
		case "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS":
		default:
			method = "OTHER"
		}
		route := publicAuditRoute(r.URL.Path)
		api := strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/api" || r.URL.Path == "/health" || r.URL.Path == "/mcp" || strings.HasPrefix(r.URL.Path, "/mcp/")
		emit := func(status int, kind, decision string) {
			service.RecordPublicAccess(identity.PublicAccessEvent{IP: peer, Channel: state.channel, UserID: state.userID, Kind: kind, Route: route, Method: method, Status: status, Decision: decision, RuleID: state.approval.RuleID, OwnerLabel: state.approval.OwnerLabel, OwnerUserID: state.approval.OwnerUserID})
		}
		aw := &publicAuditWriter{ResponseWriter: w}
		aw.onHeader = func(status int) {
			if !api && status < 400 {
				return
			}
			kind := "api_request"
			if !api {
				kind = "static_denied"
				route = "/static"
			}
			decision := state.decision
			if decision == "" {
				switch {
				case status < 400:
					decision = "allowed"
				case status == 401:
					decision = "authentication_required"
				case status == 403:
					decision = "forbidden"
				default:
					decision = "request_failed"
				}
			}
			emit(status, kind, decision)
		}
		var observed http.ResponseWriter = aw
		if _, ok := w.(http.Flusher); ok {
			observed = &publicAuditFlusher{aw}
		}
		next.ServeHTTP(observed, r)
		if aw.status == 0 {
			aw.WriteHeader(http.StatusOK)
		}
		if strings.HasPrefix(w.Header().Get("Content-Type"), "text/event-stream") && aw.status == 200 {
			decision := "stream_closed"
			if state.valid != nil && !state.valid() {
				decision = "stream_access_revoked"
			}
			emit(aw.status, "stream_end", decision)
		}
	})
}

type publicAuditWriter struct {
	http.ResponseWriter
	status   int
	onHeader func(int)
}

func (w *publicAuditWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *publicAuditWriter) WriteHeader(status int) {
	if status >= 100 && status < 200 {
		w.ResponseWriter.WriteHeader(status)
		return
	}
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
	w.onHeader(status)
}
func (w *publicAuditWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

type publicAuditFlusher struct{ *publicAuditWriter }

func (w *publicAuditFlusher) Flush() {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	w.ResponseWriter.(http.Flusher).Flush()
}

func publicAuditRoute(path string) string {
	switch path {
	case "/health", "/api/v1/auth/session", "/api/v1/auth/login", "/api/v1/auth/logout", "/api/v1/security/mfa/begin", "/api/v1/security/mfa/confirm", "/api/v1/stations", "/api/v1/points", "/api/v1/runtime", "/api/v1/runtime/events", "/api/v1/screens", "/api/v1/navigation", "/api/v1/equipment", "/api/v1/equipment/status", "/api/v1/equipment-navigation", "/api/v1/external/screens":
		return path
	}
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	if len(parts) >= 4 && parts[0] == "api" && parts[1] == "v1" {
		switch {
		case parts[2] == "screens" && len(parts) == 4:
			return "/api/v1/screens/{id}"
		case parts[2] == "equipment" && len(parts) == 4:
			return "/api/v1/equipment/{id}"
		case parts[2] == "equipment" && len(parts) == 6 && parts[4] == "photos":
			return "/api/v1/equipment/{id}/photos/{photo}"
		case parts[2] == "external" && parts[3] == "screens" && len(parts) == 6 && parts[5] == "stations":
			return "/api/v1/external/screens/{id}/stations"
		case parts[2] == "external" && parts[3] == "screens" && len(parts) == 6 && parts[5] == "query":
			return "/api/v1/external/screens/{id}/query"
		}
	}
	if strings.HasPrefix(path, "/api/") || path == "/api" || strings.HasPrefix(path, "/mcp") {
		return "/api/*"
	}
	return "/other"
}
