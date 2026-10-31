# Public read boundary — reconstructed and connected

Batch 1 saved the unconnected guard in draft PR #16. Batch 2 connects it to the
existing dedicated public HTTPS listener. This is a fresh reconstruction, not a
restoration of the lost security tree. **No production deployment or network
change has occurred.** No WAF, CrowdSec, device registration, Android transport or
IP-management UI is claimed in this small foundation.

## Public/local contract

- The primary `--listen` management listener must now be loopback in every mode.
  Previously supported directly exposed legacy/KP/identity-TLS listeners must not
  be used as public administration. Do not reverse-proxy the loopback entry.
- Public HTTPS uses managed identity and an explicit remote schema-2 IP policy.
  Its guard wraps IdentityHandler, not the reverse, so login/MFA/admin routing is
  gated as well. The same port can serve frontend assets and approved runtime
  reads; an asset-only handler is separate from the application mux, preventing
  future non-API business routes leaking through a static fallback.
- Explicit routes, not blanket GET-only: login/logout, MFA begin/confirm and the
  existing external historical query may POST. Internal history/jobs are not
  public client history. Unknown API, control/configuration/collection, account
  administration, import/export and MCP capabilities are denied for everyone,
  including admin/engineer. No header selects a mobile identity.
- Public response capabilities and request Actor grants are intersected with
  readonly. Stored users and local permissions are unchanged. Existing station,
  screen and external-screen scopes remain; an internal read-only flag preserves
  an engineer's previous external-screen read scope without restoring writes.
- Sessions carry an exact server-selected channel: empty for local/legacy,
  `public:web` for this public listener. Bearer tokens cannot cross either way,
  even after MFA. MFA upgrades retain channel; SSE validity rechecks channel and
  revocation. As before, restarting invalidates **all** sessions; no persistent
  session store was added. Necessary login/MFA cookie CSRF behavior is retained.
- Only the direct TCP RemoteAddr is trusted. Empty rules deny all, including
  assets. IPv4/IPv6 and mapped IPv4 peers work; ambiguous mapped CIDRs, zones and
  malformed entries are rejected. Owner is merely an operator label. Forwarded,
  claimed-user, user-agent and device headers cannot bypass IP policy.
- Static responses pass the existing identity Origin/Host and security-header
  policy without requiring authentication to display the login application.
  Noncanonical paths/encoded separators are rejected before nested routing.

## Explicit migration and compatibility

Existing project files/data are never silently rewritten. Schema 1 remains
accepted **only while disabled**. An enabled schema-1 file, malformed JSON/CIDR,
invalid TLS setup, public initialization error or bind failure disables public
startup but preserves loopback startup and its diagnostic/repair path. Local
`/api/v1/local/deployment` reports a fixed safe `remote_config_error`; the launcher
allows adoption only when that error is nonempty, `remote_enabled` is the Boolean
false, and the raw configuration-file digest matches exactly. A different file is
still rejected. Healthy deployment checks still include certificate/key bytes.

An operator must back up the existing configuration, create/review a disabled
schema-2 draft, explicitly supply approved peer CIDRs, confirm managed accounts
and MFA, and only then separately enable/restart after authorized deployment:

```json
{
  "schema": 2,
  "enabled": false,
  "origin": "https://203.0.113.5:18443",
  "listen": "0.0.0.0:18443",
  "certificate": "certificates/server-cert.pem",
  "private_key": "certificates/server-key.pem",
  "web_allowlist": []
}
```

The IP is documentation-only. An empty list is intentionally deny-all. Do not add
`0.0.0.0/0` as an automatic migration fallback. Existing TLS IP SAN, certificate
validity/key and normal TLS verification checks remain mandatory. IP policy and
certificate changes require restart in this phase. New package templates are
schema 2, disabled with an empty list; existing files are not replaced.

**Lifecycle limit:** configuration/initialization/bind failures are isolated at
startup. The existing `serveListeners` runtime lifecycle still shuts all listeners
down if a Serve operation fails; this batch does not promise complete runtime
fault isolation or rewrite the collector lifecycle. Existing local collection and
storage behavior and external-SQL-only client history remain unchanged.

## Fresh verification, not historical evidence

Go tests exercise peer spoofing, exact route segments, static/API isolation,
readonly response/Actor scopes, normal POST history validation, limited-scope
rejection, real login/MFA, two-way bearer isolation and actual SSE revocation.
Actual main subprocess tests use disposable IP-SAN TLS certificates with explicit
RootCAs: invalid config keeps local health/setup/login while public is unbound;
empty policy returns public403; approved peer sees safe assets; admin mutation
routes reject. No external SQL service or PostgreSQL runtime is used by these
fixtures. No Android device, browser UI or production deployment acceptance.

Compiler matches repository CI: workspace-only official Go 1.24.7 Linux amd64,
78584952 bytes, verified against `https://go.dev/dl/?mode=json&include=all`, SHA-256
`da18191ddb7db8a9339816f3e2b54bdded8047cdc2a5d67059478f8d1595c43f`.
Current full `go test ./...`, `go test -race ./...`, `go vet ./...`, Linux build
and Windows amd64 cross-build passed, as did independent focused review/tests.
The exact remote commit and CI results are recorded on PR #16. Python launcher/static checks pass; actual
PowerShell runtime test is explicitly skipped when no PowerShell is installed.
The Windows public-remote smoke script was updated and syntax checked, but was
not executed in this Linux workspace; cross-compilation is not a Windows run.
