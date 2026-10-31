# Local device registration records

## Scope and explicit non-capability

This increment stores installation-key ownership and manual review records.
**Approved means “登记审批通过，尚未开通手机访问”.** Every response states
`mobile_transport_ready: false` and `grants_access: false`. It creates no mobile
listener/session channel, client certificate, CA, private key or trust-store entry.
The existing public Web IP/read-only boundary is unchanged. Headers, user agent,
claimed device IDs and these records cannot bypass it.

A valid CSR signature proves that its creator possessed the corresponding private
key when making the request; it does not prove that the current HTTP caller owns
that key, that the key is Android Keystore non-exportable, or that a particular
physical phone/person submitted it. The SHA-256 fingerprint identifies canonical
SPKI key bytes, not a global physical-device identity. Owner and label are explicit
administrator assignments; CSR subjects are ignored for identity.

## Storage and migration

- Uses the existing identity `security_settings` connection, independent of
  engineering configuration/project restore; no new database service or file store.
- Adds only key `public_device_registrations_v1`, JSON schema 1 with revision and
  at most 256 records. No eager write, deletion or rewrite of prior settings/users.
- Missing key means no registrations. Malformed/unknown-schema/unreadable data
  returns unavailable, not a silent empty list or fallback. This record failure
  does not disable or alter existing public Web policy.
- Mutations compare the previous raw document in a transaction and write existing
  security audit metadata in the same transaction. Conflicts do not overwrite.
  Mutation responses return one consistent snapshot/revision.
- IDs are server generated. Owner/key are immutable. Disabled records are terminal;
  reassignment requires a new installation key/registration. Duplicate key material
  is rejected even if the older record is disabled. No automatic record deletion.

## Local administration contract

All routes require the local channel, loopback peer, active Manage account and
existing identity authentication/CSRF/recent-login rules. None is mounted through
the public allowlist.

- `GET /api/v1/security/devices`: full bounded snapshot.
- `POST /api/v1/security/devices`: `{revision, owner_user_id, label, csr_pem}`.
- `POST /api/v1/security/devices/{id}/approve`: `{revision, expires_at}`.
- `POST /api/v1/security/devices/{id}/disable`: `{revision}`.

Every successful mutation returns the full snapshot. Errors include 409 conflict,
503 unavailable, 422 invalid registration and 404 unknown record/action. Approval
requires a future expiration and an existing enabled owner; repeat approval can
explicitly change the registration deadline, but cannot grant transport access.
Expired approved records retain approval history; clients display their expiry.
Owner status (`active`, `disabled`, `missing`) is derived, not stored identity proof.

CSR input is at most 8 KiB, a single `CERTIFICATE REQUEST` PEM with a valid
signature and P-256 public key. Only canonical public-key PEM/fingerprint is stored;
original CSR subjects/extensions and raw CSR text are not persisted. Labels are
bounded to 128 bytes and may not contain control characters. No real private keys
are generated or accepted by the API. Tests use disposable in-memory keys only.

## Verification boundary

Identity tests cover CSR validation, duplicate keys, owner state, lifecycle and
expiry, revision races, transactional rollback, reopen/corruption and preserving
old settings. HTTP tests exercise actual local sessions and CSRF, public denial,
local-only channel restrictions, recent-login and the always-false access flags.
These fixtures are not a real PostgreSQL runtime acceptance test. No Android SDK,
Keystore attestation, actual phone enrollment, mTLS or production deployment is
claimed. A local management UI is the following small commit in this feature PR.
