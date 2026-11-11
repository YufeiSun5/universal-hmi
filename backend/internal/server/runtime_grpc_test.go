package server

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/runtimewire"
)

func TestRuntimeGRPCAndWebPublicScopesRevocationAndLegacy(t *testing.T) {
	for _, native := range []bool{false, true} {
		t.Run(map[bool]string{false: "grpc-web", true: "grpc-http2"}[native], func(t *testing.T) {
			raw, ps, engine := platform(t)
			a, err := ps.Create(points.CreateInput{Station: "A", Name: "visible", SourceType: "manual", DataType: "FLOAT", StaleMS: 60000})
			if err != nil {
				t.Fatal(err)
			}
			b, err := ps.Create(points.CreateInput{Station: "B", Name: "hidden", SourceType: "manual", DataType: "FLOAT", StaleMS: 60000})
			if err != nil {
				t.Fatal(err)
			}
			if _, err = engine.Apply(); err != nil {
				t.Fatal(err)
			}
			if err = engine.Manual(a.ID, 0.0); err != nil {
				t.Fatal(err)
			}
			if err = engine.Manual(b.ID, 99.0); err != nil {
				t.Fatal(err)
			}
			engine.RequireIdentity()
			ids, err := identity.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer ids.Close()
			owner, err := ids.Bootstrap("owner", publicFixturePassword)
			if err != nil {
				t.Fatal(err)
			}
			ids.RegisterStations([]string{"A", "B"})
			reader, err := ids.Change(ids.Actor(owner), "", identity.Change{Username: "reader", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{ids.StationID("A")}}})
			if err != nil {
				t.Fatal(err)
			}
			_, session, token, err := ids.LoginChannel("reader", publicFixturePassword, "test", false, "public:web")
			if err != nil {
				t.Fatal(err)
			}
			_, _, ownerCookie, err := ids.LoginChannel("owner", publicFixturePassword, "test", false, "public:web")
			if err != nil {
				t.Fatal(err)
			}
			var valid atomic.Bool
			valid.Store(true)
			const kpToken = "runtime-kp-fixture-token-1234567890123456789012345"
			if err = ids.LinkKPToken(reader.ID, kpToken, nil, valid.Load); err != nil {
				t.Fatal(err)
			}
			srv := httptest.NewUnstartedServer(nil)
			srv.EnableHTTP2 = true
			origin := "https://" + srv.Listener.Addr().String()
			secured, err := IdentityHandler(ids, IdentityOptions{Origin: origin, PublicReadOnly: true}, raw)
			if err != nil {
				t.Fatal(err)
			}
			public, err := PublicAccessHandler(secured, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1/32"}}, KPToken: ids.KPTokenValid})
			if err != nil {
				t.Fatal(err)
			}
			guard, err := NewPublicGuard(ids)
			if err != nil {
				t.Fatal(err)
			}
			guarded := guard.Handler(public)
			srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				t.Log("request", r.Method, r.URL.Path, time.Now())
				guarded.ServeHTTP(w, r)
				t.Log("end", r.Method, r.URL.Path, time.Now())
			})
			srv.StartTLS()
			defer srv.Close()
			option := connect.WithGRPCWeb()
			if native {
				option = connect.WithGRPC()
			}
			client := connect.NewClient[runtimewire.SubscribeRequest, runtimewire.RuntimeFrame](srv.Client(), origin+runtimeSubscribeProcedure, option)
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			request := connect.NewRequest(&runtimewire.SubscribeRequest{PointIds: []string{a.ID, b.ID}})
			request.Header().Set("Cookie", "__Host-hmi_identity="+token)
			request.Header().Set("X-CSRF-Token", session.CSRF)
			request.Header().Set("Origin", origin)
			request.Header().Set("User-Agent", "HMI-test")
			stream, err := client.CallServerStream(ctx, request)
			if err != nil {
				t.Fatal(err)
			}
			defer stream.Close()
			if !stream.Receive() {
				t.Fatal(stream.Err())
			}
			first := stream.Msg()
			if !first.Reset_ || first.Sequence != 1 || len(first.Values) != 1 || first.Values[0].PointId != a.ID || first.Values[0].Value.GetNumber() != 0 || !first.Values[0].Raw.GetNullValue() {
				t.Fatalf("bad projected reset: %v", first)
			}
			if err = engine.Manual(a.ID, 12.5); err != nil {
				t.Fatal(err)
			}
			for {
				if !stream.Receive() {
					t.Fatal(stream.Err())
				}
				if len(stream.Msg().Values) > 0 {
					break
				}
			}
			if stream.Msg().Reset_ || stream.Msg().Values[0].Value.GetNumber() != 12.5 {
				t.Fatal("delta mismatch", stream.Msg())
			}
			// An installed old client continues to receive SSE from the same server.
			old, _ := http.NewRequestWithContext(ctx, "GET", origin+"/api/v1/runtime/events?protocol=delta&ids="+a.ID+","+b.ID, nil)
			old.AddCookie(&http.Cookie{Name: "__Host-hmi_identity", Value: token})
			response, err := srv.Client().Do(old)
			if err != nil {
				t.Fatal(err)
			}
			if response.StatusCode != 200 {
				t.Fatal("legacy SSE rejected", response.StatusCode)
			}
			_, frame := readDeltaFrame(t, bufio.NewScanner(response.Body))
			response.Body.Close()
			values := frame["values"].([]any)
			if len(values) != 1 || values[0].(map[string]any)["value"] != 12.5 {
				t.Fatal("legacy parity mismatch", frame)
			}
			// Cookie CSRF stays mandatory even though the operation has no side effects.
			rejected := connect.NewRequest(&runtimewire.SubscribeRequest{})
			rejected.Header().Set("Cookie", "__Host-hmi_identity="+token)
			denied, err := client.CallServerStream(ctx, rejected)
			if err == nil {
				defer denied.Close()
				if denied.Receive() {
					t.Fatal("missing CSRF accepted")
				}
				err = denied.Err()
			}
			if err == nil {
				t.Fatal("missing CSRF accepted")
			}
			// KP bearer and a different ordinary Cookie must retain the KP viewer actor.
			kp := connect.NewRequest(&runtimewire.SubscribeRequest{AllAuthorized: true})
			kp.Header().Set("Authorization", "Bearer "+kpToken)
			kp.Header().Set("Cookie", "__Host-hmi_identity="+ownerCookie)
			kpStream, err := client.CallServerStream(ctx, kp)
			if err != nil {
				t.Fatal(err)
			}
			defer kpStream.Close()
			if !kpStream.Receive() {
				t.Fatal(kpStream.Err())
			}
			if len(kpStream.Msg().Values) != 1 || kpStream.Msg().Values[0].PointId != a.ID {
				t.Fatal("KP fell back to cookie owner")
			}
			valid.Store(false)
			for kpStream.Receive() {
			}
			if connect.CodeOf(kpStream.Err()) != connect.CodeUnauthenticated {
				t.Fatal("KP not revoked", kpStream.Err())
			}
			if err = ids.Revoke(ids.Actor(owner), reader.ID, session.ID); err != nil {
				t.Fatal(err)
			}
			for stream.Receive() {
			}
			if connect.CodeOf(stream.Err()) != connect.CodeUnauthenticated {
				t.Fatal("cookie stream not revoked", stream.Err())
			}
		})
	}
}
