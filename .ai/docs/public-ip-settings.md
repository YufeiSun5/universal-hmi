# Local public-IP policy management

This increment builds on the public readonly listener. It does not activate a
listener, change TLS certificates, install a WAF, register devices or add access
logging. The settings UI is for local account administrators only.

## Ownership and migration

- The identity persistence connection (PostgreSQL in configured deployments)
  gains `security_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)`. The
  `public_ip_policy_v1` value is a schema-1 JSON document with a revision and rules.
  Existing identity/audit rows are unchanged. This is separate from engineering
  `storage.config`, so an engineering configuration restore cannot rewrite it.
- When no stored row exists, schema-2 remote `web_allowlist` is a bootstrap only.
  Startup does not write it. First explicit save creates the authoritative row;
  subsequent startup ignores even invalid obsolete file CIDRs. TLS, enabled,
  port, origin and remote schema still belong to the deployment file.
- Invalid stored policy or a policy read failure disables public access rather
  than falling back to the file. Local management otherwise remains available;
  repair the underlying policy/file and restart after initialization failure.
  A failed save leaves the last committed in-memory policy unchanged and returns
  an error. This single-process service does not watch external SQL edits.
- Local API: `GET/PUT /api/v1/security/public-access`. PUT accepts `revision` and
  `rules`; concurrent stale edits return 409. It requires an active local-channel
  administrator, loopback peer, existing MFA/recent-login rules and cookie CSRF.
  The public capability mux never mounts it. Success is committed before response.

## Rule meaning

Rules have server-assigned ID, CIDR/IP, owner label, optional account reference,
remark, enabled flag and optional UTC expiry. At most 256 rules; empty policy
means deny all public peers. Empty owner label means not yet identified, not an
inferred identity. Unknown/disabled account references are displayed as such;
IP ownership labels never authenticate a person or device, nor revoke an account.
An IP can represent multiple users behind NAT. Direct connection IP remains the
only source; proxy/mobile headers confer no privilege.

Policy changes and expiry are checked on each public request and existing SSE
validity checks. Removing a network ends its stream without revoking its account
or session identity. Local collection, SQL history and management are unaffected.
The remote file continues to control listener activation and TLS restart behavior.

## Validation boundary

Tests use disposable SQLite fixtures through the same persistence abstraction;
this is not actual PostgreSQL runtime acceptance. They cover database precedence,
invalid/read failures, transaction rollback, revision races, expiry and owner
metadata, local auth/CSRF, real main TLS assembly and live SSE policy removal.
Exact executed checks and UI validation are recorded on the associated draft PR.

Current backend validation: complete `go test ./...`, complete `go vet ./...`,
identity package race tests and public-policy/startup server/cmd race tests passed.
The UI is a separate follow-on commit and is not included in the backend-only
checkpoint. No actual PostgreSQL service has been used.
