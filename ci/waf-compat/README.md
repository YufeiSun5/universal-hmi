# Public request WAF compatibility experiment

This is an isolated Go module, not a production middleware or an installed WAF.
The backend toolchain, listener configuration and existing data formats remain
unchanged. Run this module explicitly; the normal backend suite does not run it.
A separate Linux-only `Isolated WAF compatibility` workflow runs this experiment
with Go 1.27.3 without changing the product build matrix.

## Candidate and evidence

- Coraza 3.8.1 requires Go 1.25.0 in its tagged `go.mod`; the experiment uses
  supported Go 1.27.3, not the product's Go 1.24.7.
- OWASP CRS 4.30.0 is the candidate rule bundle. Exact module pins and bundled
  licenses must be checked before use; the frozen legacy single-module bundle
  is not a substitute for the new independently versioned bundles.
- Coraza advisories GHSA-6gcq-wc29-5xf2 (deep JSON), GHSA-6r3q-mjv7-xr8m
  (argument truncation), and GHSA-w253-m66g-rx24 (Content-Type handling) are fixed
  in 3.8.1. Selecting an affected older version to retain Go 1.24 is not acceptable.

Official sources:

- https://github.com/corazawaf/coraza/blob/v3.8.1/go.mod
- https://github.com/corazawaf/coraza/security/advisories
- https://github.com/coreruleset/coreruleset/releases/tag/v4.30.0
- https://github.com/corazawaf/coraza-coreruleset
- https://go.dev/doc/devel/release

## Proposed production boundary (not implemented)

Only the public listener would be inspected, after direct-peer IP and precise
route admission, before identity/business handling. The static branch must also
be inspected. Local management and acquisition must not depend on WAF health.
Explicitly enabled invalid WAF configuration must disable public admission,
never silently bypass protection. Audit stays outside the admission chain.

Request phases only: inspect the complete bounded body, reject unchecked tails,
restore identical inspected bytes, and close the transaction before invoking
the next handler. Do not wrap responses or hold a transaction for an SSE stream.
Disable engine audit/debug/matched-data logging; application records may include
only fixed decision codes and numeric rule IDs, not passwords or matched text.

Before integration, prove normal login/MFA/read-only POST queries, opaque
passwords, Chinese data, injection rejection, JSON/content-type/argument limits,
body preservation, early SSE flush and local-handler independence. Do not exempt
an entire login route to suppress a password false positive. Any later tuning
must be limited to an exact method/path/content type/body field with ambiguity
and duplicate-field regression tests.

Real PostgreSQL, browser, Android and deployment acceptance are not claimed by
this experiment. No CrowdSec service, firewall, certificate or credential is
created here.

## Reproduce the isolated experiment

From this directory, with an explicitly selected Go 1.27.3 binary:

```sh
GOTOOLCHAIN=local /path/to/go1.27.3/bin/go test -mod=readonly -v ./...
GOTOOLCHAIN=local /path/to/go1.27.3/bin/go test -mod=readonly -race ./...
GOTOOLCHAIN=local /path/to/go1.27.3/bin/go vet ./...
```

The official Linux/amd64 Go archive used was `go1.27.3.linux-amd64.tar.gz`,
70,588,678 bytes, SHA256
`65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40`.
Verify the official download metadata rather than trusting an unverified mirror.
The product's Go 1.24.7 remains unchanged.

Initial Linux result: ordinary reads/login/Chinese query bodies passed; SQL
injection/XSS, oversize input, deep JSON and argument overflow were rejected.
The unmodified rule set rejected valid opaque passwords resembling SQL, script
or PHP, while an ordinary quoted password passed. The baseline characterization test
reports fixed case names/outcomes only. **Passing this experiment is not product
login compatibility acceptance.** A separate tuned test connector now exercises
the narrowly scoped password exception described below.
The connector lives only in `_test.go`, uses synthetic connection metadata and
is not ready to serve traffic. Real listener wiring and application authentication remain next validation
steps, not claims made by these tests.

See [the actual dependency license inventory](THIRD_PARTY.md). Apache 2.0 for the
main candidates does not cover the MIT/BSD licenses of every transitive module.

## Narrow request-connector follow-on

`request_contract_test.go` remains test-only. It selects tuned rules only for
exact POST `/api/v1/auth/login` or `/api/v1/security/mfa/begin`, one exact
`application/json` Content-Type value, and a bounded flat JSON object with the
actual endpoint's exact keys/types. Duplicate/case-alias/unknown/nested/trailing
credential shapes are rejected, as are password query aliases. Noncanonical
content types do not get the exception; ordinary supported bodies can still pass
the baseline engine. `/mfa/confirm`, other routes and methods get no exception.

The rule uses official per-transaction
`ctl:ruleRemoveTargetByTag=OWASP_CRS;ARGS:json.password`. Only the parsed password
value is omitted from CRS targets; username, code, query, argument names and
body/parser/size limits are not disabled. See the [official ctl action
reference](https://coraza.io/docs/seclang/actions/#ctl) and [CRS tuning guidance](https://coreruleset.org/docs/2-how-crs-works/2-3-false-positives-and-tuning/).
This is exception eligibility, not authentication or device trust.

Tests compare exact original request bytes after real transaction closure and
use a loopback test HTTP server to observe an SSE frame before stream completion.
A forwarding transaction observer verifies that real `Close` runs before the
next handler; fault injection rejects a partially consumed body and close error
with fixed, secret-free reasons. Responses are neither inspected nor buffered.
These tests do not prove connection IP/auth/session integration, real TLS or
production lifecycle behavior. Neither test connector is imported by the server.

The 64 KiB cap is a ceiling, not acceptance of every smaller payload. The exact
65,536-byte whitespace-padded synthetic credential body is rejected by the engine
(`blocked_body`); 65,537 bytes is rejected by the connector (`body_limit`). These
cases do not relax the application's existing, smaller login request limit.
