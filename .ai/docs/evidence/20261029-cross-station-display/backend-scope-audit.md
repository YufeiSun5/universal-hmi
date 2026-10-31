# Cross-station display: backend scope and subscription audit

2026-10-29. Read-only source review plus isolated existing Go tests. No application/backend/installer implementation changes, production project, port 18153, real MQTT, or field equipment operations.

## Finding

Removing the process renderer's comparison between document station and point station does not widen the reviewed backend authorization boundary. A business station screen may reference a stable point ID owned by IO-01. Ownership remains IO-01; users still require access to that actual point-owning station. Screen access alone does not grant point access.

* `app/lib/main.dart:_loadConsistent` requests `/api/v1/points` without a screen-station filter. Development preview and client monitor receive the same authorized `pointIndex` / `liveIndex` dictionaries.
* `app/lib/features/process/subscriptions.dart:processSubscriptionIDs` selects node point IDs and both pipe arrow rule condition IDs. It does not filter by document station. Client screen pages use this stable-ID selection; developer preview may use the authorized catalog subscription.
* `backend/internal/points/access.go:Visible` filters definitions by `Actor.Station(p.Station)`, using the actual definition owner. Runtime reader projections also remove acquisition/configuration details.
* `backend/internal/server/process.go` and `backend/internal/process/access.go:VisibleDocument` require screen access. Runtime reader projection clears unauthorized node point IDs and arrow condition point IDs. An explicit screen grant cannot grant IO-01 data.
* `backend/internal/process/screens.go:SaveAuthorizedPoints` authorizes all referenced stable IDs through the caller's point lookup and intentionally permits authorized cross-station references.
* `backend/internal/runtime/subscription.go:selectedLocked` checks the actual active definition's station for every selected point, including dependency scope. Knowing an unauthorized ID does not return its value. Bad/offline/stale data does not become a good numeric sample; runtime readers do not receive raw samples.
* Legacy and delta SSE paths use scoped runtime snapshots. Delta rechecks session validity around serialization; session revocation stops delivery. The renderer change adds no network request or subscription scope.

No backend authorization defect was found in these reviewed paths. This is scoped source/test evidence, not a claim of exhaustive security review. An account lacking IO-01 permission should continue to show unavailable data, even when it can view a business station screen.

## Executed validation

Fixed local Go 1.24.7; `GOTOOLCHAIN=local`. Both packages passed. Full output: `backend-permissions.log`.

* `TestIdentityHTTPScopesMCPAndRevokedStream`: definition/runtime/history scope, screen projections, denied foreign access, revoked stream.
* `TestStationFirstSharedScreenHTTP`: authorized cross-station binding keeps actual point ownership; unauthorized runtime projection strips binding.
* `TestDeltaStreamSelectionHeartbeatResetRevocationAndFiftySessions`: explicitly requested unauthorized point omitted across 50 sessions; update, heartbeat/reset and revocation checks.
* `TestDeltaEmptyAndInvalidSelections`: selection bounds/empty behavior.
* `TestRuntimeStreamSnapshotUpdatesRevocationAndReconnect`: scoped stream lifecycle.
* `TestSelectedValuesRespectQualityConnectionAndTransitiveScope`: good cross-station samples allowed when authorized, foreign dependency becomes unavailable, no raw value leak, missing identity denied.

Command: `go -C backend test ./internal/server ./internal/runtime -run 'TestIdentityHTTPScopesMCPAndRevokedStream|TestStationFirstSharedScreenHTTP|TestDeltaStreamSelectionHeartbeatResetRevocationAndFiftySessions|TestDeltaEmptyAndInvalidSelections|TestRuntimeStreamSnapshotUpdatesRevocationAndReconnect|TestSelectedValuesRespectQualityConnectionAndTransitiveScope' -count=1 -v`.

## Isolated browser fixture proposal

Release agent is the sole owner of its separate PG project; proposed HTTP 18084 / PG 55436, subject to its free-port check. Keep the 5019 count by making one non-import filler a manual FLOAT point owned by IO-01, scale 1 / offset 0 / stale_ms 86400000. Activate through authenticated `POST /api/v1/apply {}` (does not connect sources), then `POST /api/v1/points/{id}/sample {"value":42.5}`. Require accepted true and runtime quality good/value 42.5.

A separate business-station document has a numeric node and pipe arrow visible/motion conditions referencing that same ID (`operator: >`, `value: 0`). A test account needs both business-screen access and IO-01 scope; a viewer without IO-01 is the negative control. This exercises real authenticated HTTP sampling, SSE and browser rendering, not MQTT acquisition. This audit did not create or mutate that fixture; browser evidence is supplied separately by its owner/root.
