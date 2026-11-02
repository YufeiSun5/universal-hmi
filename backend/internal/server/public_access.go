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
	WebAllowlist []PublicIPRule
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
	for _, route := range []string{
		"GET /health", "GET /api/v1/auth/session", "GET /api/v1/auth/captcha",
		"POST /api/v1/auth/login", "POST /api/v1/auth/logout",
		"POST /api/v1/security/mfa/begin", "POST /api/v1/security/mfa/confirm",
		"GET /api/v1/stations", "GET /api/v1/points", "GET /api/v1/runtime", "GET /api/v1/runtime/events",
		"GET /api/v1/screens", "GET /api/v1/screens/{id}", "GET /api/v1/navigation",
		"GET /api/v1/equipment", "GET /api/v1/equipment/{id}", "GET /api/v1/equipment/status",
		"GET /api/v1/equipment/{id}/photos/{photo}", "GET /api/v1/equipment-navigation",
		"GET /api/v1/external/screens", "GET /api/v1/external/screens/{id}/stations",
		"POST /api/v1/external/screens/{id}/query",
	} {
		mux.Handle(route, next)
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
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
				identityReject(w, r, 403, "public_device_denied", "设备认证未获批准")
				return
			}
			leaf = r.TLS.PeerCertificates[0]
			device, e := options.Device(leaf)
			if e != nil {
				if options.Bootstrap == nil || options.Bootstrap(leaf) != nil || !deviceBootstrapPath(r) {
					identityReject(w, r, 403, "public_device_denied", "设备认证未获批准")
					return
				}
			}
			approval = PublicIPApproval{Allowed: true, OwnerUserID: device.OwnerUserID}
			valid = func() bool { _, e := options.Device(leaf); return e == nil }
			r = r.WithContext(context.WithValue(r.Context(), publicDeviceKey{}, leaf))
		} else if err == nil && parseErr == nil && ip.Zone() == "" {
			approval = check(ip.Unmap())
		}
		if state := publicAuditStateFor(r); state != nil {
			state.approval = approval
		}
		if !approval.Allowed {
			identityReject(w, r, 403, "public_ip_denied", "来源 IP 未获公网访问批准")
			return
		}
		if leaf != nil || options.Policy != nil || options.Evaluate != nil {
			r = r.WithContext(context.WithValue(r.Context(), publicIPAccessKey{}, valid))
		}
		// Reject noncanonical/encoded separators before mux cleaning or segment matching.
		// Otherwise two stacked routers can disagree about which capability was allowed.
		escaped := strings.ToLower(r.URL.EscapedPath())
		if path.Clean(r.URL.Path) != r.URL.Path || strings.Contains(escaped, "%2f") || strings.Contains(escaped, "%5c") || strings.Contains(r.URL.Path, "\\") {
			identityReject(w, r, 403, "public_path_denied", "公网路径格式不受支持")
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
