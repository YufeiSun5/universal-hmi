package server

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/equipment"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
)

// Exercise actual TLS, public admission, identity, permission guard and services.
// The KP cases are server-linked session fixtures, not a real vendor login.
func TestOnlineMaintenanceAcrossClientChannels(t *testing.T) {
	for _, mode := range []string{"web-cookie", "web-bearer", "device-bearer", "kp-web", "kp-device"} {
		t.Run(mode, func(t *testing.T) {
			ids, owner, certs, certificate := deviceTLSFixture(t)
			if err := ids.RegisterStations([]string{"A", "B"}); err != nil {
				t.Fatal(err)
			}
			admin := ids.Actor(owner)
			grants := authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{ids.StationID("A")},
				UserManagement: true, DeviceApproval: true, CertificateManagement: true, EquipmentEdit: true}
			manager, err := ids.Change(admin, "", identity.Change{Username: "maintainer", Password: publicFixturePassword, Grants: grants})
			if err != nil {
				t.Fatal(err)
			}
			viewer, err := ids.Change(admin, "", identity.Change{Username: "reader", Password: publicFixturePassword,
				Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: grants.StationIDs}})
			if err != nil {
				t.Fatal(err)
			}
			raw, _, engine := platform(t)
			ledger, err := equipment.Open(engine.Store, t.TempDir(), func() ([]string, error) { return []string{"A", "B"}, nil })
			if err != nil {
				t.Fatal(err)
			}
			other, err := ledger.Save(context.Background(), equipment.Device{Station: "B", Code: "B1", Name: "private", Category: "水泵"})
			if err != nil {
				t.Fatal(err)
			}
			srv := httptest.NewUnstartedServer(nil)
			captchas := newLoginCaptchas()
			api, err := IdentityHandler(ids, IdentityOptions{Origin: "https://" + srv.Listener.Addr().String(), PublicReadOnly: true, captchas: captchas}, EquipmentHandler(raw, ledger, ""))
			if err != nil {
				t.Fatal(err)
			}
			srv.Config.Handler, err = PublicAccessHandler(api, PublicAccessOptions{
				WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}, Device: ids.VerifyDeviceCertificate,
			})
			if err != nil {
				t.Fatal(err)
			}
			srv.TLS, err = PublicDeviceTLS(&tls.Config{MinVersion: tls.VersionTLS12}, ids)
			if err != nil {
				t.Fatal(err)
			}
			srv.StartTLS()
			defer srv.Close()
			pool := x509.NewCertPool()
			pool.AddCert(srv.Certificate())
			tlsConfig := &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
			device := strings.Contains(mode, "device")
			if device {
				tlsConfig.Certificates = []tls.Certificate{certificate}
			}
			transport := &http.Transport{TLSClientConfig: tlsConfig}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
			type credential struct {
				token, csrf string
				cookie      *http.Cookie
			}
			call := func(c credential, method, path string, body any, origin string) (int, []byte, []*http.Cookie) {
				t.Helper()
				var data []byte
				if body != nil {
					data, err = json.Marshal(body)
					if err != nil {
						t.Fatal(err)
					}
				}
				r, e := http.NewRequest(method, srv.URL+path, strings.NewReader(string(data)))
				if e != nil {
					t.Fatal(e)
				}
				r.Header.Set("Origin", origin)
				r.Header.Set("Content-Type", "application/json")
				if c.cookie != nil {
					r.AddCookie(c.cookie)
				} else if c.token != "" {
					r.Header.Set("Authorization", "Bearer "+c.token)
				}
				if c.csrf != "" {
					r.Header.Set("X-CSRF-Token", c.csrf)
				}
				res, e := client.Do(r)
				if e != nil {
					t.Fatal(e)
				}
				defer res.Body.Close()
				data, e = io.ReadAll(res.Body)
				if e != nil {
					t.Fatal(e)
				}
				return res.StatusCode, data, res.Cookies()
			}
			var linked atomic.Bool
			linked.Store(true)
			serial := 0
			login := func(u identity.User) credential {
				t.Helper()
				if strings.HasPrefix(mode, "kp-") {
					serial++
					token := strings.Repeat("k", 40) + u.ID + strings.Repeat("x", serial)
					var leaf *x509.Certificate
					if device {
						leaf = certificate.Leaf
					}
					if e := ids.LinkKPToken(u.ID, token, leaf, linked.Load); e != nil {
						t.Fatal(e)
					}
					return credential{token: token}
				}
				code, data, cookies := call(credential{}, "POST", authLoginPath, map[string]any{
					"username": u.Username, "password": publicFixturePassword, "issue_token": mode != "web-cookie",
					"captcha_id": seedLoginCaptcha(captchas, func() string {
						if device {
							sum := sha256.Sum256(certificate.Leaf.Raw)
							return "127.0.0.1:" + hex.EncodeToString(sum[:])
						}
						return "127.0.0.1"
					}()), "captcha_answer": "12345",
				}, srv.URL)
				if code != 200 {
					t.Fatalf("login %d %s", code, data)
				}
				var session struct {
					Token string `json:"bearer_token"`
					CSRF  string `json:"csrf_token"`
				}
				if json.Unmarshal(data, &session) != nil {
					t.Fatal("session decode")
				}
				c := credential{token: session.Token, csrf: session.CSRF}
				if mode == "web-cookie" {
					if len(cookies) != 1 {
						t.Fatal("missing session cookie")
					}
					c.cookie = cookies[0]
				}
				return c
			}
			assertCode := func(c credential, method, path string, body any, want int) []byte {
				t.Helper()
				code, data, _ := call(c, method, path, body, srv.URL)
				if code != want {
					t.Fatalf("%s %s got %d want %d: %s", method, path, code, want, data)
				}
				return data
			}
			assertCode(credential{}, "GET", "/api/v1/security/devices", nil, 401)
			reader := login(viewer)
			for _, path := range []string{"/api/v1/security/users", "/api/v1/security/roles", "/api/v1/security/devices", "/api/v1/security/device-certificates", "/api/v1/security/device-owners"} {
				assertCode(reader, "GET", path, nil, 403)
			}
			assertCode(reader, "POST", "/api/v1/equipment", map[string]any{}, 403)
			maint := login(manager)
			data := assertCode(maint, "GET", authSessionPath, nil, 200)
			var session map[string]any
			if json.Unmarshal(data, &session) != nil {
				t.Fatal("decode session")
			}
			for _, key := range []string{"can_manage_users", "can_approve_devices", "can_manage_certificates", "can_edit_equipment"} {
				if session[key] != true {
					t.Fatal("missing capability", key)
				}
			}
			for _, key := range []string{"can_write", "can_develop", "can_manage_security", "can_edit_equipment_navigation"} {
				if session[key] != false {
					t.Fatal("ungranted capability", key)
				}
			}
			data = assertCode(maint, "GET", "/api/v1/security/users", nil, 200)
			if strings.Contains(string(data), owner.ID) {
				t.Fatal("out-of-scope account visible")
			}
			for _, path := range []string{"/api/v1/write", "/api/v1/apply", "/api/v1/security/public-access", "/api/v1/security/network-access", "/api/v1/security/kp-settings", "/mcp"} {
				assertCode(maint, "POST", path, map[string]any{}, 403)
			}
			create := identity.Change{Username: "new operator", Password: publicFixturePassword,
				Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: grants.StationIDs, EquipmentEdit: true}}
			if mode == "web-cookie" {
				noCSRF := maint
				noCSRF.csrf = ""
				assertCode(noCSRF, "POST", "/api/v1/security/users", create, 403)
			}
			if code, _, _ := call(maint, "POST", "/api/v1/security/users", create, "https://other.invalid"); code != 403 {
				t.Fatal("cross origin accepted", code)
			}
			data = assertCode(maint, "POST", "/api/v1/security/users", create, 200)
			var created identity.User
			if json.Unmarshal(data, &created) != nil {
				t.Fatal("user decode")
			}
			create.Version, create.Password = created.Version, ""
			create.Grants.AllStations = true
			assertCode(maint, "PUT", "/api/v1/security/users/"+created.ID, create, 403)
			create.Grants.AllStations = false
			create.Username = "renamed operator"
			assertCode(maint, "PUT", "/api/v1/security/users/"+created.ID, create, 200)
			assertCode(maint, "PUT", "/api/v1/security/users/"+created.ID, create, 422)
			assertCode(maint, "POST", "/api/v1/security/roles", identity.Role{Name: "excessive", Grants: authorization.Grants{Roles: []string{"admin"}}}, 403)
			assertCode(maint, "POST", "/api/v1/security/roles", identity.Role{Name: "ledger editors", Grants: authorization.Grants{Roles: []string{"viewer"}, EquipmentEdit: true}}, 200)
			assertCode(maint, "POST", "/api/v1/security/sessions/revoke", map[string]any{"user_id": owner.ID}, 403)
			assertCode(maint, "POST", "/api/v1/security/mfa/reset", map[string]any{"user_id": owner.ID}, 403)
			assertCode(maint, "GET", "/api/v1/security/device-certificates", nil, 200)
			data = assertCode(maint, "GET", "/api/v1/security/device-owners", nil, 200)
			if strings.Contains(string(data), "grants") || strings.Contains(string(data), "password") {
				t.Fatal("owner lookup leaked policy")
			}
			// Reconfirm an existing public leaf, keeping its stable registration and key.
			assertCode(maint, "POST", "/api/v1/security/device-certificates/"+certs.Items[0].RegistrationID+"/approve", map[string]any{
				"revision": certs.Revision, "leaf_pem": certs.Items[0].LeafPEM, "expires_at": certs.Items[0].ExpiresAt,
			}, 200)
			if device {
				// Reapproval rotates the exact transport approval; the old session is stale.
				assertCode(maint, "GET", "/api/v1/security/devices", nil, 401)
				maint = login(manager)
			}
			data = assertCode(maint, "GET", "/api/v1/security/devices", nil, 200)
			var regs identity.DeviceRegistrationSnapshot
			if json.Unmarshal(data, &regs) != nil {
				t.Fatal("registration decode")
			}
			data = assertCode(maint, "POST", "/api/v1/security/devices", map[string]any{
				"revision": regs.Revision, "owner_user_id": viewer.ID, "label": "online enrollment", "csr_pem": deviceRecordCSR(t),
			}, 200)
			if json.Unmarshal(data, &regs) != nil {
				t.Fatal("registration decode")
			}
			id := regs.Items[len(regs.Items)-1].ID
			assertCode(maint, "POST", "/api/v1/security/devices/"+id+"/approve", map[string]any{"revision": regs.Revision, "expires_at": time.Now().Add(time.Hour)}, 200)
			d := equipment.Device{Station: "A", Code: "A1", Name: "online pump", Category: "水泵"}
			data = assertCode(maint, "POST", "/api/v1/equipment", d, 200)
			if json.Unmarshal(data, &d) != nil {
				t.Fatal("equipment decode")
			}
			d.Name = "updated online pump"
			assertCode(maint, "POST", "/api/v1/equipment", d, 200)
			assertCode(maint, "POST", "/api/v1/equipment", d, 409)
			d.Station = "B"
			assertCode(maint, "POST", "/api/v1/equipment", d, 403)
			other.Station = "A"
			assertCode(maint, "POST", "/api/v1/equipment", other, 404)
			assertCode(maint, "PUT", "/api/v1/equipment-navigation", equipment.Navigation{}, 403)
			if strings.HasPrefix(mode, "kp-") {
				linked.Store(false)
				assertCode(maint, "POST", "/api/v1/equipment", d, 401)
				linked.Store(true)
				maint = login(manager)
			}
			grants.EquipmentEdit = false
			if _, err = ids.Change(admin, manager.ID, identity.Change{Username: manager.Username, Version: manager.Version, Grants: grants}); err != nil {
				t.Fatal(err)
			}
			assertCode(maint, "POST", "/api/v1/equipment", d, 401)
			manager, err = ids.User(manager.ID)
			if err != nil {
				t.Fatal(err)
			}
			maint = login(manager)
			assertCode(maint, "POST", "/api/v1/equipment", d, 403)
			assertCode(maint, "GET", "/api/v1/security/devices", nil, 200)
		})
	}
}
