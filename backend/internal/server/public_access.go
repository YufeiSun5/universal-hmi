package server

import (
	"context"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"path"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

// PublicIPRule approves a network, not a person or a mobile installation.
type PublicIPRule struct {
	CIDR  string `json:"cidr"`
	Owner string `json:"owner,omitempty"`
}

type PublicIPApproval struct {
	Allowed                         bool
	RuleID, OwnerLabel, OwnerUserID string
}

type PublicAccessOptions struct {
	// LANDevelopment only expands the API transport on an independent LAN
	// listener. Identity and application authorization still guard every call.
	LANDevelopment bool
	// KP routes authenticate their own proofs and do not require Web IP approval.
	KP http.Handler
	// KPToken validates a live linked identity, never just the presence of a bearer.
	KPToken func(string, *x509.Certificate) bool
	// KPExternalToken retrieves a scoped supplier capability's bound HMI token.
	// The token must still pass KPToken before it can replace IP admission.
	KPExternalToken func(*http.Request) string
	WebAllowlist    []PublicIPRule
	// Policy, when set, is authoritative; the file list is only a bootstrap.
	Policy   func(netip.Addr) bool
	Evaluate func(netip.Addr) PublicIPApproval
	// Device validates only certificates proven by the TLS handshake. Nil disables
	// mobile admission. A presented invalid certificate never falls back to IP.
	Device func(*x509.Certificate) (identity.DeviceCertificate, error)
	// Bootstrap allows only sign-in/assets for an unknown installation key.
	Bootstrap func(*x509.Certificate) error
	// Static must serve only frontend assets, never the application/API mux.
	// Keeping it separate ensures future non-/api business routes are not exposed.
	Static http.Handler
	// External serves only the fixed supplier capability gateway, never HMI APIs.
	External http.Handler
}

// PublicAccessHandler is a transport capability boundary, not authentication.
// It must wrap the public IdentityHandler; local handlers must remain separate.
// Only the direct TCP peer is trusted. No header selects an IP or mobile channel.
// This constructor alone does not enable a listener or modify configuration.
func PublicAccessHandler(next http.Handler, options PublicAccessOptions) (http.Handler, error) {
	if next == nil {
		return nil, fmt.Errorf("public API handler is required")
	}
	networks := make([]netip.Prefix, 0, len(options.WebAllowlist))
	rules := options.WebAllowlist
	if options.Policy != nil || options.Evaluate != nil {
		rules = nil
	}
	for _, rule := range rules {
		var prefix netip.Prefix
		if ip, err := netip.ParseAddr(rule.CIDR); err == nil && ip.Zone() == "" {
			ip = ip.Unmap()
			prefix = netip.PrefixFrom(ip, ip.BitLen())
		} else {
			var err error
			prefix, err = netip.ParsePrefix(rule.CIDR)
			if err != nil || prefix.Addr().Is4In6() || prefix.Addr().Zone() != "" {
				return nil, fmt.Errorf("invalid public allowlist IP/CIDR")
			}
		}
		networks = append(networks, prefix.Masked())
	}
	if options.Policy != nil && options.Evaluate != nil {
		return nil, fmt.Errorf("public policy must have one authoritative evaluator")
	}
	check := func(ip netip.Addr) PublicIPApproval {
		if options.Evaluate != nil {
			return options.Evaluate(ip)
		}
		if options.Policy != nil {
			return PublicIPApproval{Allowed: options.Policy(ip)}
		}
		for i, network := range networks {
			if network.Contains(ip) {
				return PublicIPApproval{Allowed: true, OwnerLabel: rules[i].Owner}
			}
		}
		return PublicIPApproval{}
	}
	mux := http.NewServeMux()
	kpMux := http.NewServeMux()
	if options.KP != nil {
		for _, route := range []string{"POST /api/v1/kp/bootstrap", "POST /api/v1/kp/poll", "POST /api/v1/kp/close", "POST /api/v1/kp/logoff-result", "OPTIONS /api/v1/kp/bootstrap", "OPTIONS /api/v1/kp/poll", "OPTIONS /api/v1/kp/close", "OPTIONS /api/v1/kp/logoff-result", "POST /api/v1/web/redeem", "GET /api/v1/web/me", "GET /api/v1/web/status", "POST /api/v1/web/logout", "GET /kp/"} {
			mux.Handle(route, options.KP)
			kpMux.Handle(route, options.KP)
		}
	}
	for _, route := range []string{
		"GET /health", "GET /api/v1/auth/session", "GET /api/v1/auth/captcha",
		"GET /api/v1/auth/presence",
		"POST " + runtimeSubscribeProcedure,
		"POST /api/v1/auth/login", "POST /api/v1/auth/logout",
		"POST /api/v1/security/mfa/begin", "POST /api/v1/security/mfa/confirm",
		"GET /api/v1/stations", "GET /api/v1/points", "GET /api/v1/runtime", "GET /api/v1/runtime/events",
		"GET /api/v1/screens", "GET /api/v1/screens/{id}", "GET /api/v1/navigation", "GET /api/v1/live-overview",
		"GET /api/v1/live-overview/control-status",
		"GET /api/v1/equipment", "GET /api/v1/equipment/{id}", "GET /api/v1/equipment/status",
		"GET /api/v1/equipment/{id}/photos/{photo}", "GET /api/v1/equipment-navigation",
		"GET /api/v1/external/screens/{id}/heat-prices",
		"GET /api/v1/external/screens", "GET /api/v1/external/screens/{id}/stations",
		"GET /api/v1/external-sites",
		"GET /api/v1/total-reports", "GET /api/v1/total-reports/{kind}/{year}",
		"GET /api/v1/total-reports/{kind}/{year}/changes", "POST /api/v1/total-reports/{kind}/{year}/changes",
		"GET /api/v1/total-reports/{kind}/{year}/locks", "POST /api/v1/total-reports/{kind}/{year}/locks",
		"GET /api/v1/total-reports/{kind}/{year}/checkpoints", "POST /api/v1/total-reports/{kind}/{year}/checkpoints",
		"POST /api/v1/total-reports/{kind}/{year}/rollback", "GET /api/v1/total-reports/{kind}/{year}/export",
		"POST /api/v1/total-reports/{kind}/{year}/heat-sync", "GET /api/v1/total-reports/heat-bindings",
		"GET /api/v1/total-reports/{kind}/{year}/heat-readings",
		"GET /api/v1/security/public-access/events",
		"POST /api/v1/external/screens/{id}/query",
		// Online maintenance is a narrow route allowlist; identity and each
		// application service independently require the named capability.
		"GET /api/v1/security/users", "POST /api/v1/security/users", "PUT /api/v1/security/users/{id}",
		"GET /api/v1/security/roles", "POST /api/v1/security/roles", "PUT /api/v1/security/roles/{id}",
		"DELETE /api/v1/security/roles/{id}", "POST /api/v1/security/roles/{id}/members",
		"GET /api/v1/security/stations", "GET /api/v1/security/sessions", "POST /api/v1/security/sessions/revoke",
		"POST /api/v1/security/password", "POST /api/v1/security/mfa/reset",
		"GET /api/v1/security/device-owners", "GET /api/v1/security/devices", "POST /api/v1/security/devices",
		"POST /api/v1/security/devices/{id}/approve", "POST /api/v1/security/devices/{id}/approve-login", "POST /api/v1/security/devices/{id}/disable",
		"GET /api/v1/security/device-certificates", "POST /api/v1/security/device-certificates/{id}/approve", "POST /api/v1/security/device-certificates/{id}/revoke",
		"POST /api/v1/equipment", "POST /api/v1/equipment/{id}/photos", "DELETE /api/v1/equipment/{id}/photos/{photo}",
		"PUT /api/v1/equipment-navigation",
	} {
		mux.Handle(route, next)
	}
	if options.External != nil {
		mux.Handle("/external-sites/", options.External)
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if options.LANDevelopment && strings.HasPrefix(r.URL.Path, "/api/v1/") {
			next.ServeHTTP(w, r)
			return
		}
		for _, prefix := range []string{"/api", "/mcp", "/mobile"} {
			if r.URL.Path == prefix || strings.HasPrefix(r.URL.Path, prefix+"/") {
				identityReject(w, r, 403, "public_read_only", "公网仅开放明确批准的只读能力")
				return
			}
		}
		if r.Method != "GET" && r.Method != "HEAD" {
			identityReject(w, r, 403, "public_read_only", "公网仅开放明确批准的只读能力")
			return
		}
		if options.Static == nil {
			http.NotFound(w, r)
			return
		}
		options.Static.ServeHTTP(w, r)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		ip, parseErr := netip.ParseAddr(host)
		approval := PublicIPApproval{}
		var leaf *x509.Certificate
		valid := func() bool { return check(ip.Unmap()).Allowed }
		if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
			if state := publicAuditStateFor(r); state != nil {
				state.channel = "public:device"
			}
			if options.Device == nil || !r.TLS.HandshakeComplete {
				identityReject(w, r, 403, "public_device_denied", "设备证书未获批准、已停用、撤销或过期，请联系管理员检查设备审批和证书")
				return
			}
			leaf = r.TLS.PeerCertificates[0]
			device, e := options.Device(leaf)
			if e != nil {
				if options.Bootstrap == nil || options.Bootstrap(leaf) != nil || !deviceBootstrapPath(r) {
					identityReject(w, r, 403, "public_device_denied", "设备证书未获批准、已停用、撤销或过期，请联系管理员检查设备审批和证书")
					return
				}
			}
			approval = PublicIPApproval{Allowed: true, OwnerUserID: device.OwnerUserID}
			valid = func() bool { _, e := options.Device(leaf); return e == nil }
			r = r.WithContext(context.WithValue(r.Context(), publicDeviceKey{}, leaf))
		} else if err == nil && parseErr == nil && ip.Zone() == "" {
			approval = check(ip.Unmap())
		}
		// KP entry/assets authenticate inside the bridge. Subsequent business
		// requests need a verified linked session; headers and ordinary cookies
		// alone never select this independent admission path.
		_, kpRoute := kpMux.Handler(r)
		kpAdmission := options.KP != nil && kpRoute != ""
		if kpAdmission {
			approval = PublicIPApproval{Allowed: true}
			valid = func() bool { return true } // Bridge operations check their own proof/lease.
		} else if options.KP != nil && options.KPToken != nil {
			token := bearer(r)
			if token == "" && options.KPExternalToken != nil && strings.HasPrefix(r.URL.Path, embeddedPrefix) {
				token = options.KPExternalToken(r)
			}
			if token != "" && options.KPToken(token, leaf) {
				kpAdmission = true
				approval = PublicIPApproval{Allowed: true}
				valid = func() bool { return options.KPToken(token, leaf) }
			}
		}
		if state := publicAuditStateFor(r); state != nil {
			state.approval = approval
		}
		if !approval.Allowed {
			identityReject(w, r, 403, "public_ip_denied", "来源 IP 未获公网访问批准")
			return
		}
		if kpAdmission || leaf != nil || options.Policy != nil || options.Evaluate != nil {
			r = r.WithContext(context.WithValue(r.Context(), publicIPAccessKey{}, valid))
		}
		// Reject noncanonical/encoded separators before mux cleaning or segment matching.
		// Otherwise two stacked routers can disagree about which capability was allowed.
		escaped := strings.ToLower(r.URL.EscapedPath())
		canonical := path.Clean(r.URL.Path)
		if options.KP != nil && r.URL.Path == "/kp/" {
			canonical = "/kp/"
		}
		// Supplier roots and directories legitimately end in one slash. Preserve
		// that suffix only in the isolated supplier namespace; cleaning must still
		// leave every segment unchanged. HMI API route matching stays strict.
		if strings.HasPrefix(r.URL.Path, embeddedPrefix) && strings.HasSuffix(r.URL.Path, "/") {
			canonical += "/"
		}
		// The bundled report entry is a directory index. Permit this exact
		// static path without relaxing canonical paths for APIs or other assets.
		if r.URL.Path == "/total-reports/" {
			canonical += "/"
		}
		if canonical != r.URL.Path || strings.Contains(escaped, "%2f") || strings.Contains(escaped, "%5c") || strings.Contains(r.URL.Path, "\\") {
			message := "公网路径格式不受支持"
			if options.LANDevelopment {
				message = "内网路径格式不受支持"
			}
			identityReject(w, r, 403, "public_path_denied", message)
			return
		}
		mux.ServeHTTP(w, r)
	}), nil
}

func deviceBootstrapPath(r *http.Request) bool {
	if r.URL.Path == authLoginPath {
		return r.Method == http.MethodPost
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	if r.URL.Path == authSessionPath || r.URL.Path == "/api/v1/auth/captcha" {
		return true
	}
	return !strings.HasPrefix(r.URL.Path, "/api") && !strings.HasPrefix(r.URL.Path, "/mcp") && !strings.HasPrefix(r.URL.Path, "/mobile") && r.URL.Path != "/health"
}

// The public wrapper supplies a live check for long-running authenticated reads.
type publicIPAccessKey struct{}
type publicDeviceKey struct{}

func publicDeviceLeaf(r *http.Request) *x509.Certificate {
	leaf, _ := r.Context().Value(publicDeviceKey{}).(*x509.Certificate)
	return leaf
}

func publicIPAccessValid(r *http.Request) bool {
	if guard, ok := r.Context().Value(publicGuardKey{}).(func() bool); ok && !guard() {
		return false
	}
	valid, ok := r.Context().Value(publicIPAccessKey{}).(func() bool)
	return !ok || valid()
}
