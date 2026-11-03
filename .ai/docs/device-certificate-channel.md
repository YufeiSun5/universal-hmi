# Device certificate channel contract

## Trust and current delivery boundary

This increment is being developed in small commits. Its first checkpoint adds
local certificate approval records only. Until TLS, session binding and the
assembled transport tests are delivered, it does **not** enable mobile access.
The existing device-registration approval continues to grant no access itself.

The trust model is an administrator-approved **exact leaf-certificate DER pin**
plus possession of its private key proved by a completed TLS handshake. It is
not CA-chain trust, certificate issuance, Android Keystore attestation, a
physical-phone identifier or proof of a telephone number. A separately issued
or self-signed leaf can be explicitly approved; trusting one leaf does not trust
its issuer or another certificate with the same public key. Subject, issuer and
SAN fields do not assign an account owner.

Only public certificate material is accepted/stored. No private key, CA signing
key or production credential is generated or imported. Tests use disposable
keys and certificates only. Clients must still verify the server certificate,
including its fixed-IP SAN; this design does not disable server TLS validation.

## Persistent approval

The identity store owns a separate `public_device_certificates_v1` document in
`security_settings`, with schema 1, a monotonic revision and at most one current
certificate approval per registered installation. Missing data means no
approvals; malformed or unavailable data never becomes an empty successful
policy. Existing registration/account/project documents are not replaced.

An approval records the registration ID, its server-derived owner, canonical
SPKI SHA-256, exact leaf SHA-256/public PEM, approval time/actor, expiry and
revocation time. Each explicit approval or replacement receives a fresh random
`approval_id`; a previously issued session must not revive after the same leaf
is approved again. Certificate validity and approval expiry must fit within
the registration authorization window. The leaf must match the registered
P-256 key, be non-CA and allow digital signatures and explicit client auth.

Writes use the existing identity connection, document compare-and-swap and
same-transaction audit. Certificate approval guards the registration document
before updating the certificate document. Registration reapproval (including
an expiry edit) atomically revokes any current certificate approval, requiring
a new explicit certificate approval. This prevents shortening and later
extending registration expiry from reviving old access. Registration disable
remains available even when certificate records are corrupt; reapproval may
fail closed in that situation. No automatic renewal or CA trust expansion occurs.

Local management routes are under `/api/v1/security/device-certificates` and
require the existing local channel, loopback peer, manager authorization,
CSRF and recent-login checks. They are never added to the public route allowlist.
Approval is a separate action from device registration approval.

## Planned transport integration and acceptance gate

`mobile_enabled` defaults to false. Disabled mode retains `NoClientCert` for
existing Web compatibility: a certificate merely configured in a client, but
not negotiated/presented, is not a verified device identity. Web still requires
its IP policy and account authentication. Enabling mobile uses the same HTTPS
listener with optional client certificates. A presented unapproved, expired,
revoked or otherwise invalid certificate must fail rather than fall back to
Web. No header, user agent or self-reported device ID selects the channel.

The TLS verification callback rechecks live approval on ordinary and resumed
handshakes. It does not by itself prove private-key possession: the Go TLS
handshake must complete its CertificateVerify check before HTTP is admitted.
Every HTTP request and authenticated stream additionally rechecks current
registration, certificate approval, expiry and owner validity. Mobile sessions
bind the channel, installation ID, exact leaf fingerprint and approval ID;
the account authenticated with password/MFA must be the registered owner.
Account permissions are intersected with the same public read-only route and
capability boundary, including for administrators. Local management and
acquisition are not routed through this mobile policy.

The integration must prove TLS 1.2 and 1.3, actual session resumption, wrong-key
and certificate-only failures, unapproved same-key replacement, owner mismatch,
cross-device/channel token rejection, MFA, expiry, keepalive and SSE revocation.
Configuration changes require explicit restart; a disabled channel cannot
convert an old mobile session into a Web session. Real Android/Keystore and
PostgreSQL deployment validation remain separate from these software fixtures.
