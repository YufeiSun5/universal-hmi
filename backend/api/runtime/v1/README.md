# Runtime subscription protocol

`runtime.proto` is the shared latest-state contract. The HTTP mount is
`/api/v1/hmi.runtime.v1.RuntimeService/Subscribe`; its `/api/v1` prefix keeps
the existing identity, CSRF, device/KP, permission and ingress boundaries.
Connect-Go 1.18.1 serves binary gRPC-Web and native gRPC over HTTP/2. The shipped
Flutter clients (Windows/Web/KP/Android bundled Web) use binary gRPC-Web over
the existing trusted HTTP adapters. Android retains pinned server TLS and its
installation client certificate. There is no proxy port or Envoy requirement.

The request distinguishes all-authorized, explicit selected IDs (empty means
health only), and the authorized overview scope. Every connection starts with
reset; epoch, sequence and active version prevent mixing old snapshots or gaps.
Values retain null, boolean, string and number types. Meta JSON carries the
existing extensible runtime health/configuration fields, never sample values.
No replay or physical commands are part of this service. Sampling remains 500ms.

`/health` advertises `runtime_transport=grpc-web-v1`. Every new subscription
negotiates again, so program rollback to an older healthy server uses legacy SSE
without an APK downgrade. Authentication, permission, network or RPC errors do
not trigger downgrade. Old APKs continue using the unchanged SSE/HTTP endpoints.

Generated files are checked in. Regenerate using protoc 31.1,
protoc-gen-go 1.36.11, protoc-gen-dart 22.0.1 (Dart protobuf 4.2.0):

```text
protoc -I backend/api/runtime/v1 --go_out=backend/internal/runtimewire --go_opt=paths=source_relative --dart_out=app/lib/shared/runtimewire backend/api/runtime/v1/runtime.proto
dart format app/lib/shared/runtimewire
```

Server framing is maintained by Connect. The small Dart binary gRPC-Web adapter
uses the existing HTTP client's certificate, cookie, cancellation and streaming
behavior; it enforces frame/trailer bounds, terminal status and delta sequence.
Tests cover fragmented messages, malformed/truncated frames, auth revocation,
TLS/WAF integration, native gRPC interoperability, old SSE coexistence and the
Android native proxy's immediate binary forwarding.
