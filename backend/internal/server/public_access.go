package server

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"path"
	"strings"
)

// PublicIPRule approves a network, not a person or a mobile installation.
type PublicIPRule struct {
	CIDR  string `json:"cidr"`
	Owner string `json:"owner,omitempty"`
}

type PublicAccessOptions struct {
	WebAllowlist []PublicIPRule
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
	for _, rule := range options.WebAllowlist {
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
	mux := http.NewServeMux()
	for _, route := range []string{
		"GET /health", "GET /api/v1/auth/session",
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
				writeError(w, 403, "public_read_only", "公网仅开放明确批准的只读能力")
				return
			}
		}
		if r.Method != "GET" && r.Method != "HEAD" {
			writeError(w, 403, "public_read_only", "公网仅开放明确批准的只读能力")
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
		allowed := false
		if err == nil && parseErr == nil && ip.Zone() == "" {
			for _, network := range networks {
				if network.Contains(ip.Unmap()) {
					allowed = true
					break
				}
			}
		}
		if !allowed {
			writeError(w, 403, "public_ip_denied", "来源 IP 未获公网访问批准")
			return
		}
		// Reject noncanonical/encoded separators before mux cleaning or segment matching.
		// Otherwise two stacked routers can disagree about which capability was allowed.
		escaped := strings.ToLower(r.URL.EscapedPath())
		if path.Clean(r.URL.Path) != r.URL.Path || strings.Contains(escaped, "%2f") || strings.Contains(escaped, "%5c") || strings.Contains(r.URL.Path, "\\") {
			writeError(w, 403, "public_path_denied", "公网路径格式不受支持")
			return
		}
		mux.ServeHTTP(w, r)
	}), nil
}
