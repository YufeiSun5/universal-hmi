# Public read boundary — reconstruction batch 1

**Not connected to the running application yet.** This batch introduces and tests
`server.PublicAccessHandler` only. Existing remote schema 1/listener behavior is
unchanged and must not be described as protected by this helper. The draft PR must
remain unready until listener/configuration migration and identity/session-channel
integration are independently tested. No deployment or network change occurs.

## Contract

- Explicit routes, not a blanket GET-only filter: login/logout, MFA begin/confirm,
  and the existing external historical query may POST. Internal history/jobs are
  not public client history. Unknown API, control/configuration/collection,
  account administration, import/export and MCP capabilities are denied even if
  the caller later authenticates as administrator.
- Only a valid TCP RemoteAddr matching a configured IP/CIDR is accepted. Empty
  rules deny all, including assets. IPv4/IPv6 and mapped IPv4 peers are supported;
  ambiguous mapped CIDRs, zones and invalid rules are rejected. Owner is a label,
  never an authenticated identity. Forwarded/mobile/device headers do not bypass.
- Public API and frontend file serving are separate handler arguments: unmatched
  non-API GET/HEAD goes only to the supplied asset handler, not to the business
  mux. Noncanonical paths and encoded separators are rejected before routing.
- This is not authentication. The eventual assembly must place this guard outside
  IdentityHandler, retain MFA/scopes, intersect public capabilities with readonly,
  isolate local/public sessions, and leave the local management handler unwrapped.
  No mobile identity is implemented by this batch.

## Verification

New synthetic handler tests cover peers/spoofing, invalid configuration, explicit
POST read/auth exceptions, admin/write/private routes, path segments and encoding,
asset/API separation and unchanged local handler. These are helper contracts, not
assembled listener, real authentication, SSE or production acceptance. The lost
previous branch's tests/hashes are not evidence for this reconstruction.

The repository pins Go 1.24.7 in CI. A fresh workspace-only official Linux amd64
compiler was checksum-verified against `https://go.dev/dl/?mode=json&include=all`:
`go1.24.7.linux-amd64.tar.gz`, 78584952 bytes, SHA-256
`da18191ddb7db8a9339816f3e2b54bdded8047cdc2a5d67059478f8d1595c43f`.
No product toolchain upgrade, system installation, SDK license, security service
or credential creation is involved. Actual results will be recorded in the PR.

Fresh cloud result (2026-10-31): `go test -mod=readonly ./internal/server -run
TestPublicBoundary -count=1` passed. Independent read-only review found no blocking
issue in this unconnected batch. Aggregate Go checks are tracked on the draft PR;
no historical result is reused. Static response security headers and bidirectional
local/public bearer isolation remain explicit integration requirements.
