package server

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/materials"
)

func materialDecode[T any](t *testing.T, raw []byte) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestMaterialsAuthenticatedTLSChannels(t *testing.T) {
	for _, mode := range []string{"web-cookie", "web-bearer", "device-bearer", "kp-web", "kp-device"} {
		t.Run(mode, func(t *testing.T) {
			ids, owner, _, certificate := deviceTLSFixture(t)
			admin := ids.Actor(owner)
			grants := authorization.Grants{Roles: []string{"viewer"}, MaterialsRequest: true, MaterialsApprove: true, MaterialsInbound: true, MaterialsOutbound: true, MaterialsCatalog: true}
			warehouse, err := ids.Change(admin, "", identity.Change{Username: "warehouse", Password: publicFixturePassword, Grants: grants})
			if err != nil {
				t.Fatal(err)
			}
			requester, err := ids.Change(admin, "", identity.Change{Username: "requester", Password: publicFixturePassword, Grants: authorization.Grants{Roles: []string{"viewer"}, MaterialsRequest: true}})
			if err != nil {
				t.Fatal(err)
			}
			raw, _, engine := platform(t)
			store, err := materials.Open(engine.Store.DB)
			if err != nil {
				t.Fatal(err)
			}
			srv := httptest.NewUnstartedServer(nil)
			captchas := newLoginCaptchas()
			api, err := IdentityHandler(ids, IdentityOptions{Origin: "https://" + srv.Listener.Addr().String(), PublicReadOnly: true, captchas: captchas}, MaterialsHandler(raw, store, ""))
			if err != nil {
				t.Fatal(err)
			}
			srv.Config.Handler, err = PublicAccessHandler(api, PublicAccessOptions{WebAllowlist: []PublicIPRule{{CIDR: "127.0.0.1"}}, Device: ids.VerifyDeviceCertificate})
			if err != nil {
				t.Fatal(err)
			}
			srv.TLS, err = PublicDeviceTLS(&tls.Config{MinVersion: tls.VersionTLS12}, ids)
			if err != nil {
				t.Fatal(err)
			}
			guard, err := NewPublicGuard(ids)
			if err != nil {
				t.Fatal(err)
			}
			srv.Config.Handler = guard.Handler(srv.Config.Handler)
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
				r, e := http.NewRequest(method, srv.URL+path, bytes.NewReader(data))
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
					token := strings.Repeat("k", 40) + u.ID + fmt.Sprint(serial)
					var leaf *x509.Certificate
					if device {
						leaf = certificate.Leaf
					}
					if err := ids.LinkKPToken(u.ID, token, leaf, linked.Load); err != nil {
						t.Fatal(err)
					}
					return credential{token: token}
				}
				key := "127.0.0.1"
				if device {
					sum := sha256.Sum256(certificate.Leaf.Raw)
					key += ":" + hex.EncodeToString(sum[:])
				}
				code, data, cookies := call(credential{}, "POST", authLoginPath, map[string]any{"username": u.Username, "password": publicFixturePassword, "issue_token": mode != "web-cookie", "captcha_id": seedLoginCaptcha(captchas, key), "captcha_answer": "12345"}, srv.URL)
				if code != 200 {
					t.Fatalf("login %d %s", code, data)
				}
				var session struct {
					Token string `json:"bearer_token"`
					CSRF  string `json:"csrf_token"`
				}
				if json.Unmarshal(data, &session) != nil {
					t.Fatal("invalid login response")
				}
				c := credential{token: session.Token, csrf: session.CSRF}
				if mode == "web-cookie" {
					if len(cookies) != 1 {
						t.Fatal("missing cookie")
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
			op := func() materials.Mutation {
				serial++
				return materials.Mutation{OperationID: fmt.Sprintf("test-operation-%d", serial)}
			}
			assertCode(credential{}, "GET", "/api/v1/materials/stock", nil, 401)
			wh, rq := login(warehouse), login(requester)
			assertCode(rq, "GET", "/api/v1/materials/stock", nil, 403)
			assertCode(rq, "POST", "/api/v1/materials/categories", map[string]any{"operation_id": "denied", "name": "denied"}, 403)
			for _, path := range []string{"/api/v1/write", "/api/v1/apply", "/mcp"} {
				assertCode(wh, "POST", path, map[string]any{}, 403)
			}
			if mode == "web-cookie" {
				noCSRF := wh
				noCSRF.csrf = ""
				assertCode(noCSRF, "POST", "/api/v1/materials/categories", map[string]any{}, 403)
			}
			if code, _, _ := call(wh, "POST", "/api/v1/materials/categories", map[string]any{}, "https://invalid.example"); code != 403 {
				t.Fatal("cross-origin mutation", code)
			}
			cat := materialDecode[materials.Category](t, assertCode(wh, "POST", "/api/v1/materials/categories", materials.CategoryInput{Mutation: op(), Category: materials.Category{Name: "正常"}}, 200))
			scrap := materialDecode[materials.Category](t, assertCode(wh, "POST", "/api/v1/materials/categories", materials.CategoryInput{Mutation: op(), Category: materials.Category{Name: "废品"}}, 200))
			item := materialDecode[materials.Item](t, assertCode(wh, "POST", "/api/v1/materials/items", materials.ItemInput{Mutation: op(), Item: materials.Item{Name: "阀门", Unit: "个", CategoryID: cat.ID, Price: "12.5", Warning: "2"}}, 200))
			img, e := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGP0qJjNgA0wYRUdtBIAEyYBa74a5twAAAAASUVORK5CYII=")
			if e != nil {
				t.Fatal(e)
			}
			asset := materialDecode[materials.Asset](t, assertCode(wh, "POST", "/api/v1/materials/assets", materials.AssetInput{Mutation: op(), Name: "签名.png", Kind: "signature", Data: img}, 200))
			sig := materialDecode[materials.Signature](t, assertCode(wh, "POST", "/api/v1/account/signature", materials.SignatureInput{Mutation: op(), Signature: materials.Signature{AssetID: asset.ID}}, 200))
			app := materialDecode[materials.Application](t, assertCode(rq, "POST", "/api/v1/materials/applications", materials.ApplicationInput{Mutation: op(), Text: "维修采购阀门"}, 200))
			assertCode(wh, "POST", "/api/v1/materials/applications/"+app.ID+"/decision", materials.ApprovalInput{Mutation: op(), Version: 1, Decision: "approved"}, 200)
			receipt := materialDecode[materials.Asset](t, assertCode(wh, "POST", "/api/v1/materials/assets", materials.AssetInput{Mutation: op(), Name: "凭证.png", Kind: "receipt", Data: img}, 200))
			for _, n := range []string{"10", "5"} {
				assertCode(wh, "POST", "/api/v1/materials/inbound", materials.DocumentInput{Mutation: op(), ApplicationID: app.ID, ApplicationVersion: 1, AssetIDs: []string{receipt.ID}, Lines: []materials.LineInput{{ItemID: item.ID, CategoryID: cat.ID, Quantity: n}}}, 200)
			}
			trace := materialDecode[materials.ApplicationDetail](t, assertCode(rq, "GET", "/api/v1/materials/applications/"+app.ID+"?limit=1", nil, 200))
			if trace.Inbound.Total != 2 || trace.Totals[0].Quantity != "15" || len(trace.Inbound.Items[0].AssetIDs) != 0 {
				t.Fatal("trace projection", trace)
			}
			assertCode(rq, "GET", "/api/v1/materials/assets/"+receipt.ID, nil, 404)
			preview := materialDecode[materials.OutboundPreview](t, assertCode(wh, "POST", "/api/v1/materials/outbound-preview", materials.DocumentInput{Lines: []materials.LineInput{{ItemID: item.ID, CategoryID: cat.ID, Quantity: "5"}}}, 200))
			command := materials.DocumentInput{Mutation: op(), Purpose: "日常维修领用", SignatureVersion: sig.Version, Lines: preview.Inputs}
			out := materialDecode[materials.Document](t, assertCode(wh, "POST", "/api/v1/materials/outbound", command, 200))
			if out.KnownAmount != "62.50" {
				t.Fatal(out)
			}
			replay := materialDecode[materials.Document](t, assertCode(wh, "POST", "/api/v1/materials/outbound", command, 200))
			if replay.ID != out.ID {
				t.Fatal("HTTP retry duplicated")
			}
			stock := materialDecode[materials.Page[materials.Balance]](t, assertCode(wh, "GET", "/api/v1/materials/stock", nil, 200)).Items[0]
			assertCode(wh, "POST", "/api/v1/materials/transfer", materials.DocumentInput{Mutation: op(), Lines: []materials.LineInput{{ItemID: item.ID, CategoryID: cat.ID, TargetCategoryID: scrap.ID, Quantity: "4", ItemVersion: stock.Version, BalanceVersion: stock.BalanceVersion}}}, 200)
			for i, n := range []string{"2", "3"} {
				target := scrap.ID
				if i == 1 {
					target = cat.ID
				}
				assertCode(wh, "POST", "/api/v1/materials/return", materials.DocumentInput{Mutation: op(), SourceID: out.ID, SignatureVersion: sig.Version, Lines: []materials.LineInput{{SourceLineID: out.Lines[0].ID, Quantity: n, TargetCategoryID: target}}}, 200)
			}
			detail := materialDecode[materials.DocumentDetail](t, assertCode(wh, "GET", "/api/v1/materials/documents/"+out.ID, nil, 200))
			if detail.Document.Status != "returned" || detail.Returns.Total != 2 {
				t.Fatal("HTTP return trace", detail)
			}
			chains := materialDecode[materials.Page[materials.ChainSummary]](t, assertCode(wh, "GET", "/api/v1/materials/chains?kind=outbound&category_id="+scrap.ID, nil, 200))
			if chains.Total != 1 || chains.Items[0].ID != out.ID {
				t.Fatal("chain category projection", chains)
			}
			chain := materialDecode[materials.ChainDetail](t, assertCode(wh, "GET", "/api/v1/materials/chains/outbound/"+out.ID, nil, 200))
			if chain.Nodes.Total != 3 || chain.Chain.Lines[0].Remaining != "0" {
				t.Fatal("HTTP chain nodes", chain)
			}
			assertCode(rq, "GET", "/api/v1/materials/chains/outbound/"+out.ID, nil, 404)
			limitedChain := materialDecode[materials.ChainDetail](t, assertCode(rq, "GET", "/api/v1/materials/chains/application/"+app.ID, nil, 200))
			if limitedChain.Nodes.Total != 4 || !limitedChain.Nodes.Items[2].SummaryOnly || len(limitedChain.Nodes.Items[2].Document.AssetIDs) != 0 {
				t.Fatal("HTTP chain summary", limitedChain)
			}
			workbook := assertCode(wh, "GET", "/api/v1/materials/documents/"+out.ID+"/export", nil, 200)
			if !bytes.HasPrefix(workbook, []byte("PK")) {
				t.Fatal("not Excel")
			}
			assertCode(rq, "GET", "/api/v1/materials/documents/"+out.ID+"/export", nil, 403)
			assertCode(wh, "POST", "/api/v1/account/signature", materials.SignatureInput{Mutation: op(), Signature: materials.Signature{Version: sig.Version}, Delete: true}, 200)
			current := materialDecode[materials.Signature](t, assertCode(wh, "GET", "/api/v1/account/signature", nil, 200))
			if current.AssetID != "" || current.Version != 2 {
				t.Fatal("delete current signature", current)
			}
			history := materialDecode[materials.Page[materials.SignatureVersion]](t, assertCode(wh, "GET", "/api/v1/account/signature/history", nil, 200))
			if history.Total != 2 || history.Items[0].Action != "deleted" || history.Items[1].AssetID != asset.ID {
				t.Fatal("own signature history", history)
			}
			otherHistory := materialDecode[materials.Page[materials.SignatureVersion]](t, assertCode(rq, "GET", "/api/v1/account/signature/history?user_id="+warehouse.ID, nil, 200))
			if otherHistory.Total != 0 {
				t.Fatal("signature history query escaped own identity")
			}
			assertCode(wh, "GET", "/api/v1/materials/assets/"+asset.ID, nil, 200)
			retained := materialDecode[materials.DocumentDetail](t, assertCode(wh, "GET", "/api/v1/materials/documents/"+out.ID, nil, 200))
			if retained.Document.SignatureID != asset.ID {
				t.Fatal("delete changed signed document")
			}
			balances := materialDecode[materials.Page[materials.Balance]](t, assertCode(wh, "GET", "/api/v1/materials/stock", nil, 200))
			for _, b := range balances.Items {
				want := "9"
				if b.StockCategoryID == scrap.ID {
					want = "6"
				}
				if b.Quantity != want || b.TotalQuantity != "15" {
					t.Fatal("HTTP ledger mismatch", balances)
				}
			}
			if strings.HasPrefix(mode, "kp-") {
				linked.Store(false)
				assertCode(wh, "GET", "/api/v1/materials/stock", nil, 401)
				linked.Store(true)
			}
			warehouse, err = ids.Change(admin, warehouse.ID, identity.Change{Username: warehouse.Username, Grants: authorization.Grants{Roles: []string{"viewer"}}, Version: warehouse.Version})
			if err != nil {
				t.Fatal(err)
			}
			assertCode(wh, "GET", "/api/v1/materials/stock", nil, 401)
			wh = login(warehouse)
			assertCode(wh, "GET", "/api/v1/materials/stock", nil, 403)
			assertCode(wh, "GET", "/api/v1/materials/chains", nil, 403)
			assertCode(wh, "GET", "/api/v1/materials/assets/"+receipt.ID, nil, 404)
			assertCode(wh, "GET", "/api/v1/account/signature/history", nil, 200)
		})
	}
}
