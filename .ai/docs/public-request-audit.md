# Public request records, version 1

This is server-side request evidence, **not proof of page viewing**. The public
listener records API requests, unsuccessful static requests (HTTP 4xx/5xx), and
one completion event for an admitted SSE connection. Successful static resources
are deliberately omitted. No navigation-event endpoint, phone identity, WAF,
CrowdSec service or production activation is included.

## Data and authorization

The identity persistence connection adds `public_access_events` and an `at` index;
existing `audit` schema and rows are untouched. The table is isolated from
engineering config import/restore. The version-1 record shape consists of:

- database sequence, server UTC timestamp, direct peer IP and fixed public channel;
- verified authenticated account ID when resolved, otherwise empty;
- fixed request kind, method, route template, HTTP status and decision enum;
- approving rule ID and the owner label/account annotation at request time.

An owner annotation is **not** the authenticated account or proof of who used a
shared IP. Changing current rule ownership never rewrites older records. No raw
URL, query, body, password, token, response data or arbitrary error text is stored.
Unknown paths become fixed sentinel categories; dynamic IDs are replaced by
route templates. Forwarded/client-user/device headers cannot supply attribution.
Login failure is distinguished from a request without valid authentication;
not every 401/403 means a malicious attempt.

Only local-channel loopback administrators can read
`GET /api/v1/security/public-access/events?before=<seq>&limit=<1..200>` under the
existing identity/MFA checks. The public mux never exposes this API. No delete,
retention-setting or public event-submission API is added. Responses contain
`items`, `next_before` and recording status; unavailable reads return 503 rather
than pretending there are no records. The settings UI is under user management,
shows at most 500 loaded records and labels partial/old/error states.

## Bounded work, retention and gaps

- Nonblocking queue of 256, one consumer, transaction batches of at most 32, and
  three-second database contexts. A full queue or database failure loses events;
  counters are exposed locally. This is **not a complete forensic audit trail**.
- Fixed 14-day age policy and 100,000 stored-event cap. Hourly cleanup also runs
  while idle, and capacity is reclaimed before inserts. Deletes use bounded
  1,000-row batches. Backlog or cleanup failure pauses inserts until cleanup can
  catch up; therefore physical removal can lag the age cutoff under backlog or
  database failure. Reads exclude age-expired rows. No indefinite background
  retry framework or external daemon is installed.
- Recording errors do not grant access or stop local collection/storage. The IP
  and readonly/authentication checks remain authoritative. Failed recording is
  visible as dropped/write-failure counters or an unavailable read, not green
  protection status. Counters are process-local and reset on restart.
- Shutdown stops scheduling batches and lets the active batch finish within its
  existing three-second database deadline. It counts abandoned queue items and
  joins the worker before closing its database; it does not promise a successful
  drain or cancel an active SQL operation merely because shutdown was requested.
- An SSE admission is recorded at response start; completion records a fixed
  normal-close or invalid-access reason, not every frame or sampled value.

## Current verification boundary

Synthetic tests cover strict field/template bounds and secret omission, direct
peer/verified-user versus manual-owner attribution, login-failure classification,
real TLS startup/read API protection, SSE revocation, paging, physical idle
cleanup, cap enforcement, failed writes/cleanup recovery, queue saturation and
idempotent shutdown. Current full Go tests/vet, public identity/server/startup race checks, full app
analyze and 308 Flutter tests pass. Web build, independent review and exact
remote-head CI are tracked in the draft PR.

Storage fixtures use SQLite through the PostgreSQL-capable persistence adapter;
no actual PostgreSQL runtime acceptance or live installation is claimed. UI
widget checks do not constitute browser screenshots or native visual acceptance.
