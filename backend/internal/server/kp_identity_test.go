package server

import (
	"context"
	"encoding/json"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/kpbridge"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestKPManagedIdentityScopesMFAAndBothRevocations(t *testing.T) {
	raw, ps, _ := platform(t)
	pa, _ := ps.Create(points.CreateInput{Station: "A", Name: "visible", SourceType: "manual", DataType: "FLOAT"})
	pb, _ := ps.Create(points.CreateInput{Station: "B", Name: "hidden", SourceType: "manual", DataType: "FLOAT"})
	ids, err := identity.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer ids.Close()
	owner, err := ids.Bootstrap("owner", "long security fixture password")
	if err != nil {
		t.Fatal(err)
	}
	ids.RegisterStations([]string{"A", "B"})
	user, err := ids.Change(ids.Actor(owner), "", identity.Change{Username: "KP user", Password: "long security fixture password", Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{ids.StationID("A")}}})
	if err != nil {
		t.Fatal(err)
	}
	verifiedMFA := false
	bridge, err := kpbridge.New(kpbridge.Options{SourceID: "kp", WorkspaceID: "default", Grants: []kpbridge.Grant{{Subject: "subject", UserID: user.ID, DisplayName: "KP display", Role: "operator"}}, Verifier: kpbridge.VerifyFunc(func(_ context.Context, _ string, b kpbridge.Bootstrap) (kpbridge.Identity, error) {
		return kpbridge.Identity{Subject: "subject", UserName: b.UserName, MFA: verifiedMFA, AuthenticatedAt: time.Now()}, nil
	})})
	if err != nil {
		t.Fatal(err)
	}
	const origin = "https://hmi.example"
	iam, err := IdentityHandler(ids, IdentityOptions{Origin: origin}, raw)
	if err != nil {
		t.Fatal(err)
	}
	h, err := KPHandler(bridge, KPOptions{PublicOrigin: origin, KPOrigins: []string{"https://kp.example"}, Identity: ids}, iam, raw)
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, origin+path, strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		if token == "" {
			r.Header.Del("Authorization")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	redeem := func(contextID string) *httptest.ResponseRecorder {
		boot, err := bridge.Bootstrap(context.Background(), kpbridge.Bootstrap{ContextID: contextID, LoginVersion: "1", UserName: "KP display"}, "test")
		if err != nil {
			t.Fatal(err)
		}
		return call("POST", "/api/v1/web/redeem", `{"ticket":"`+boot.Ticket+`"}`, "")
	}
	if w := redeem("no-mfa"); w.Code != 401 {
		t.Fatal("missing MFA allowed", w.Code, w.Body)
	}
	verifiedMFA = true
	tokenFrom := func(w *httptest.ResponseRecorder) string {
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body)
		}
		var v map[string]any
		json.Unmarshal(w.Body.Bytes(), &v)
		if v["can_develop"] != false || v["can_write"] != false {
			t.Fatal("legacy operator escalated", v)
		}
		return v["webToken"].(string)
	}
	token := tokenFrom(redeem("first"))
	if w := call("GET", "/api/v1/points", "", token); w.Code != 200 || !strings.Contains(w.Body.String(), pa.ID) || strings.Contains(w.Body.String(), pb.ID) {
		t.Fatal("scope", w.Code, w.Body)
	}
	if w := call("POST", "/api/v1/apply", "{}", token); w.Code != 403 {
		t.Fatal("KP development bypass", w.Code)
	}
	_, sess, err := ids.Resolve(token, false)
	if err != nil {
		t.Fatal(err)
	}
	if err = ids.Revoke(ids.Actor(owner), user.ID, sess.ID); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/api/v1/points", "/api/v1/web/me", "/api/v1/web/status"} {
		if w := call("GET", path, "", token); w.Code != 401 {
			t.Fatal("identity revoke bypass", path, w.Code)
		}
	}
	token = tokenFrom(redeem("second"))
	if _, err = bridge.Logout(token); err != nil {
		t.Fatal(err)
	}
	if w := call("GET", "/api/v1/points", "", token); w.Code != 401 {
		t.Fatal("bridge logout bypassed via fallback", w.Code, w.Body)
	}
	if _, _, err = ids.Resolve(token, false); err == nil {
		t.Fatal("linked session outlived bridge")
	}
}
