package materials

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/xuri/excelize/v2"
)

func need[T any](t *testing.T, v T, e error) T {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
	return v
}

// tuple arguments cannot follow another argument in Go; use this helper for
// result pairs to keep each call's assertion attached to its error.
func must[T any](v T, e error) func(*testing.T) T {
	return func(t *testing.T) T { t.Helper(); return need(t, v, e) }
}
func testContext(user string, g authorization.Grants) context.Context {
	return authorization.WithActor(context.Background(), authorization.Actor{ID: user, DisplayName: user, Grants: g, Valid: func() bool { return true }})
}
func allGrants() authorization.Grants {
	return authorization.Grants{Roles: []string{"viewer"}, MaterialsRequest: true, MaterialsApprove: true, MaterialsInbound: true, MaterialsOutbound: true, MaterialsCatalog: true}
}
func operation() Mutation { return Mutation{OperationID: id()} }
func imageBytes(c color.NRGBA) []byte {
	m := image.NewNRGBA(image.Rect(0, 0, 40, 20))
	m.SetNRGBA(2, 2, c)
	var b bytes.Buffer
	_ = png.Encode(&b, m)
	return b.Bytes()
}

func testService(t *testing.T, pg bool) *Service {
	t.Helper()
	var db *persistence.DB
	if pg {
		dsn := os.Getenv("HMI_MATERIALS_TEST_PG_DSN")
		if dsn == "" {
			t.Skip("isolated PostgreSQL DSN not supplied")
		}
		admin := must(persistence.Open("", dsn))(t)
		schema := "materials_test_" + id()
		_, e := admin.Exec("CREATE SCHEMA " + schema)
		if e != nil {
			admin.Close()
			t.Fatal(e)
		}
		t.Cleanup(func() {
			_, e := admin.Exec("DROP SCHEMA " + schema + " CASCADE")
			if e != nil {
				t.Error(e)
			}
			admin.Close()
		})
		parsed := must(url.Parse(dsn))(t)
		params := parsed.Query()
		params.Set("search_path", schema)
		parsed.RawQuery = params.Encode()
		db = must(persistence.Open("", parsed.String()))(t)
		var activeSchema string
		if e := db.QueryRow("SELECT current_schema()").Scan(&activeSchema); e != nil || activeSchema != schema {
			db.Close()
			t.Fatalf("test schema isolation failed: %q %v", activeSchema, e)
		}
	} else {
		db = must(persistence.Open(filepath.Join(t.TempDir(), "materials.sqlite"), ""))(t)
	}
	t.Cleanup(func() { db.Close() })
	s := must(Open(db))(t)
	must(Open(db))(t)
	return s
}
func sign(t *testing.T, s *Service, ctx context.Context, c color.NRGBA) Signature {
	t.Helper()
	asset := must(s.Upload(ctx, AssetInput{Mutation: operation(), Name: "signature.png", Kind: "signature", Data: imageBytes(c)}))(t)
	old := must(s.Signature(ctx))(t)
	return must(s.SaveSignature(ctx, SignatureInput{Mutation: operation(), Signature: Signature{AssetID: asset.ID, Version: old.Version}}))(t)
}

type fixture struct {
	s             *Service
	ctx, reviewer context.Context
	normal, scrap Category
	item          Item
	sig           Signature
}

func setup(t *testing.T, pg bool) fixture {
	f := fixture{s: testService(t, pg), ctx: testContext("warehouse", allGrants()), reviewer: testContext("reviewer", allGrants())}
	f.normal = must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "正常"}}))(t)
	f.scrap = must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "废品"}}))(t)
	f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: "物料A", Unit: "个", CategoryID: f.normal.ID, Price: "12.5", Warning: "3"}}))(t)
	f.sig = sign(t, f.s, f.ctx, color.NRGBA{R: 255, A: 255})
	sign(t, f.s, f.reviewer, color.NRGBA{B: 255, A: 255})
	return f
}
func (f fixture) stock(t *testing.T, category string) Balance {
	t.Helper()
	p := must(f.s.Stock(f.ctx, Filter{ItemID: f.item.ID, CategoryID: category}))(t)
	if len(p.Items) != 1 {
		t.Fatalf("stock %+v", p)
	}
	return p.Items[0]
}
func (f fixture) inbound(t *testing.T, n string, app Application) Document {
	t.Helper()
	return must(f.s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), ApplicationID: app.ID, ApplicationVersion: app.Version, Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: n, Price: "10"}}}))(t)
}
func (f fixture) outboundInput(t *testing.T, n string) DocumentInput {
	t.Helper()
	b := f.stock(t, f.normal.ID)
	return DocumentInput{Mutation: operation(), SignatureVersion: f.sig.Version, Purpose: "日常维修领用", Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: n, ItemVersion: b.Version, BalanceVersion: b.BalanceVersion}}}
}

func TestWarehouseEndToEnd(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			request := testContext("requester", authorization.Grants{MaterialsRequest: true})
			app := must(s.Submit(request, ApplicationInput{Mutation: operation(), Text: "维修需要一批材料"}))(t)
			must(s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "rejected", Reason: "请说明用途"}))(t)
			app = must(s.Submit(request, ApplicationInput{Mutation: operation(), ID: app.ID, Version: 1, Text: "泵房维修需要材料"}))(t)
			app = must(s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 2, Decision: "approved"}))(t)
			f.inbound(t, "10", app)
			f.inbound(t, "5", app)
			trace := must(s.Application(request, app.ID, Filter{Limit: 1}))(t)
			if len(trace.Versions) != 2 || trace.Versions[0].Text != "维修需要一批材料" || trace.Inbound.Total != 2 || len(trace.Inbound.Items) != 1 || trace.Totals[0].Quantity != "15" {
				t.Fatalf("trace %+v", trace)
			}
			if trace.Inbound.Items[0].Lines[0].Price != "" {
				t.Fatal("applicant leaked price")
			}
			input := f.outboundInput(t, "5")
			out := must(s.Confirm(f.ctx, "outbound", input))(t)
			if out.KnownAmount != "62.50" {
				t.Fatalf("amount %+v", out)
			}
			replay := must(s.Confirm(f.ctx, "outbound", input))(t)
			if replay.ID != out.ID || f.stock(t, f.normal.ID).Quantity != "10" {
				t.Fatal("duplicate posting")
			}
			b := f.stock(t, f.normal.ID)
			must(s.Confirm(f.ctx, "transfer", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, TargetCategoryID: f.scrap.ID, Quantity: "4", ItemVersion: b.Version, BalanceVersion: b.BalanceVersion}}}))(t)
			if f.stock(t, f.normal.ID).Quantity != "6" || f.stock(t, f.scrap.ID).Quantity != "4" {
				t.Fatal("transfer imbalance")
			}
			ret := DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "2", TargetCategoryID: f.scrap.ID}}}
			r := must(s.Confirm(f.ctx, "return", ret))(t)
			if r.KnownAmount != "25.00" {
				t.Fatal(r)
			}
			ret.Mutation = operation()
			ret.Lines[0].Quantity = "3"
			ret.Lines[0].TargetCategoryID = f.normal.ID
			must(s.Confirm(f.ctx, "return", ret))(t)
			detail := must(s.Document(f.ctx, out.ID, Filter{Limit: 1}))(t)
			if detail.Document.Status != "returned" || detail.Document.Lines[0].Remaining != "0" || detail.Returns.Total != 2 {
				t.Fatal(detail)
			}
			if f.stock(t, f.normal.ID).Quantity != "9" || f.stock(t, f.scrap.ID).Quantity != "6" || f.stock(t, f.normal.ID).TotalQuantity != "15" {
				t.Fatal("return imbalance")
			}
			ret.Mutation = operation()
			if _, e := s.Confirm(f.ctx, "return", ret); !errors.Is(e, ErrStock) {
				t.Fatalf("overreturn: %v", e)
			}
			f.item.Price = "20"
			f.item.Name = "新名称"
			must(s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
			sign(t, s, f.ctx, color.NRGBA{G: 255, A: 255})
			data, _, e := s.Export(f.ctx, out.ID)
			if e != nil {
				t.Fatal(e)
			}
			x := must(excelize.OpenReader(bytes.NewReader(data)))(t)
			defer x.Close()
			if must(x.GetCellValue("出库单", "G5"))(t) != "12.5" || must(x.GetCellValue("出库单", "H5"))(t) != "62.50" || must(x.GetCellValue("出库单", "B5"))(t) != "物料A" {
				t.Fatal("historical snapshot drift")
			}
			pics := must(x.GetPictures("出库单", "F11"))(t)
			if len(pics) != 1 {
				t.Fatalf("signature pictures %d", len(pics))
			}
			_, originalSig, e := s.Asset(f.ctx, out.SignatureID)
			if e != nil {
				t.Fatal(e)
			}
			if !bytes.Equal(pics[0].File, originalSig) {
				t.Fatal("signature changed")
			}
			// Reopening the repository preserves the committed state and snapshots.
			reopened := must(Open(s.db))(t)
			if must(reopened.Document(f.ctx, out.ID, Filter{}))(t).Document.Status != "returned" {
				t.Fatal("reopen lost return")
			}
		})
	}
}

func TestAtomicityConcurrencyAndIdempotency(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			f.inbound(t, "10", Application{})
			first := f.outboundInput(t, "7")
			second := first
			second.Mutation = operation()
			var wg sync.WaitGroup
			results := make(chan error, 2)
			for _, in := range []DocumentInput{first, second} {
				wg.Add(1)
				go func(in DocumentInput) { defer wg.Done(); _, e := f.s.Confirm(f.ctx, "outbound", in); results <- e }(in)
			}
			wg.Wait()
			close(results)
			success := 0
			for e := range results {
				if e == nil {
					success++
				} else if !errors.Is(e, ErrConflict) && !errors.Is(e, ErrStock) {
					t.Fatal(e)
				}
			}
			if success != 1 || f.stock(t, f.normal.ID).Quantity != "3" {
				t.Fatal("concurrent overspend")
			}
			bad := f.outboundInput(t, "2")
			other := must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: Item{Name: "无库存", Unit: "个", CategoryID: f.normal.ID, Warning: "0"}}))(t)
			bad.Lines = append(bad.Lines, LineInput{ItemID: other.ID, CategoryID: f.normal.ID, Quantity: "1", ItemVersion: other.Version})
			before := must(f.s.Documents(f.ctx, "outbound", Filter{}))(t).Total
			if _, e := f.s.Confirm(f.ctx, "outbound", bad); !errors.Is(e, ErrStock) {
				t.Fatal(e)
			}
			if f.stock(t, f.normal.ID).Quantity != "3" || must(f.s.Documents(f.ctx, "outbound", Filter{}))(t).Total != before {
				t.Fatal("partial transaction committed")
			}
			in := f.outboundInput(t, "1")
			out := must(f.s.Confirm(f.ctx, "outbound", in))(t)
			in.Lines[0].Quantity = "2"
			if _, e := f.s.Confirm(f.ctx, "outbound", in); !errors.Is(e, ErrConflict) {
				t.Fatal("operation collision", e)
			}
			ret := DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: f.scrap.ID}}}
			results = make(chan error, 2)
			for i := 0; i < 2; i++ {
				copy := ret
				copy.Mutation = operation()
				wg.Add(1)
				go func() { defer wg.Done(); _, e := f.s.Confirm(f.ctx, "return", copy); results <- e }()
			}
			wg.Wait()
			close(results)
			success = 0
			for e := range results {
				if e == nil {
					success++
				} else if !errors.Is(e, ErrStock) {
					t.Fatal(e)
				}
			}
			if success != 1 {
				t.Fatal("concurrent overreturn")
			}
		})
	}
}

func TestAuthorizationVersionsAndValidation(t *testing.T) {
	f := setup(t, false)
	no := testContext("no", authorization.Grants{Roles: []string{"admin", "engineer"}, AllStations: true})
	if _, e := f.s.Stock(no, Filter{}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("implicit admin stock", e)
	}
	app := must(f.s.Submit(f.ctx, ApplicationInput{Mutation: operation(), Text: "材料"}))(t)
	if _, e := f.s.Approve(f.ctx, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"}); e == nil {
		t.Fatal("self approved")
	}
	if _, e := f.s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "rejected"}); e == nil {
		t.Fatal("empty rejection")
	}
	noSig := testContext("nosig", allGrants())
	if _, e := f.s.Approve(noSig, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"}); !errors.Is(e, ErrSignature) {
		t.Fatal("missing signature", e)
	}
	if _, e := f.s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), ApplicationID: app.ID, ApplicationVersion: 1, Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "1"}}}); e == nil {
		t.Fatal("pending inbound")
	}
	must(f.s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"}))(t)
	if _, e := f.s.Submit(f.ctx, ApplicationInput{Mutation: operation(), ID: app.ID, Version: 1, Text: "rewrite"}); !errors.Is(e, ErrConflict) {
		t.Fatal("rewrote approval")
	}
	f.inbound(t, "2", Application{})
	out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
	if _, e := f.s.Confirm(f.reviewer, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: f.normal.ID}}}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("other return", e)
	}
	if _, _, e := f.s.Asset(no, out.SignatureID); !errors.Is(e, ErrMissing) {
		t.Fatal("asset leaked", e)
	}
	parent := f.normal
	for i := 2; i <= 10; i++ {
		parent = must(f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "子类", ParentID: parent.ID}}))(t)
	}
	if _, e := f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "11", ParentID: parent.ID}}); e == nil {
		t.Fatal("eleventh level")
	}
	f.normal.ParentID = parent.ID
	if _, e := f.s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: f.normal}); e == nil {
		t.Fatal("category cycle")
	}
	for _, v := range []string{"-1", "1.00001", "NaN", "1e2", " 1", "999999999999"} {
		if _, e := units(v, false); e == nil {
			t.Fatal("invalid quantity", v)
		}
	}
	for _, data := range [][]byte{[]byte("not an image"), make([]byte, MaxImageBytes+1)} {
		if _, e := f.s.Upload(f.ctx, AssetInput{Mutation: operation(), Kind: "receipt", Name: "fake.png", Data: data}); e == nil {
			t.Fatal("invalid image accepted")
		}
	}
}

func TestPricesAndConfirmationDrift(t *testing.T) {
	f := setup(t, false)
	f.inbound(t, "10", Application{})
	in := f.outboundInput(t, "1")
	f.item.Price = "0"
	f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
	if _, e := f.s.Confirm(f.ctx, "outbound", in); !errors.Is(e, ErrConflict) {
		t.Fatal("silent price change", e)
	}
	out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
	if out.KnownAmount != "0.00" || out.MissingPrices != 0 {
		t.Fatal("zero price", out)
	}
	f.item.Price = ""
	f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
	out = must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
	if out.Lines[0].Amount != "" || out.MissingPrices != 1 {
		t.Fatal("missing price", out)
	}
	if v := must(amount(15000, "0.335"))(t); v != "0.50" {
		t.Fatal(v)
	}
	if v := must(amount(10000, "0.005"))(t); v != "0.01" {
		t.Fatal(v)
	}
	if _, e := f.s.Confirm(f.ctx, "outbound", DocumentInput{Mutation: operation(), Purpose: "用途", SignatureVersion: 0, Lines: in.Lines}); !errors.Is(e, ErrConflict) {
		t.Fatal("signature drift", e)
	}
}
