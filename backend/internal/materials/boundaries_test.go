package materials

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"sync"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/xuri/excelize/v2"
)

func TestSinglePermissionsAndResourceProjection(t *testing.T) {
	f := setup(t, false)
	receipt := must(f.s.Upload(f.ctx, AssetInput{Mutation: operation(), Kind: "receipt", Name: "凭证.png", Data: imageBytes(color.NRGBA{R: 1, A: 255})}))(t)
	app := must(f.s.Submit(f.ctx, ApplicationInput{Mutation: operation(), Text: "本人的材料申请"}))(t)
	app = must(f.s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"}))(t)
	in := must(f.s.Confirm(f.ctx, "inbound", DocumentInput{Mutation: operation(), ApplicationID: app.ID, ApplicationVersion: 1, AssetIDs: []string{receipt.ID}, Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, Quantity: "10"}}}))(t)
	out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "2")))(t)
	for _, permission := range []string{"none", "request", "approve", "inbound", "outbound", "catalog"} {
		t.Run(permission, func(t *testing.T) {
			g := authorization.Grants{}
			switch permission {
			case "request":
				g.MaterialsRequest = true
			case "approve":
				g.MaterialsApprove = true
			case "inbound":
				g.MaterialsInbound = true
			case "outbound":
				g.MaterialsOutbound = true
			case "catalog":
				g.MaterialsCatalog = true
			}
			ctx := testContext("warehouse", g)
			_, err := f.s.Stock(ctx, Filter{})
			stock := permission == "inbound" || permission == "outbound" || permission == "catalog"
			if (err == nil) != stock {
				t.Fatalf("stock %s %v", permission, err)
			}
			_, err = f.s.Applications(ctx, Filter{})
			if (err == nil) != (permission == "request" || permission == "approve" || permission == "inbound") {
				t.Fatalf("application %s %v", permission, err)
			}
			_, err = f.s.Document(ctx, in.ID, Filter{})
			if (err == nil) != (permission == "inbound") {
				t.Fatalf("inbound %s %v", permission, err)
			}
			_, err = f.s.Document(ctx, out.ID, Filter{})
			if (err == nil) != (permission == "outbound") {
				t.Fatalf("outbound %s %v", permission, err)
			}
			_, _, err = f.s.Export(ctx, out.ID)
			if (err == nil) != (permission == "outbound") {
				t.Fatalf("export %s %v", permission, err)
			}
			_, _, err = f.s.Asset(ctx, receipt.ID)
			if (err == nil) != (permission == "inbound") {
				t.Fatalf("receipt after revoke %s %v", permission, err)
			}
			if stock {
				moves := must(f.s.Movements(ctx, Filter{}))(t)
				for _, m := range moves.Items {
					if m.Kind != permission {
						t.Fatalf("movement leaked %s %+v", permission, m)
					}
				}
			}
		})
	}
	other := testContext("other", authorization.Grants{MaterialsRequest: true})
	if _, err := f.s.Application(other, app.ID, Filter{}); !errors.Is(err, ErrMissing) {
		t.Fatalf("other applicant %v", err)
	}
	if got := must(f.s.Applications(other, Filter{}))(t); got.Total != 0 {
		t.Fatal("count leaked", got)
	}
	requester := testContext("warehouse", authorization.Grants{MaterialsRequest: true})
	detail := must(f.s.Application(requester, app.ID, Filter{}))(t)
	if len(detail.Inbound.Items) != 1 || len(detail.Inbound.Items[0].AssetIDs) != 0 || detail.Inbound.Items[0].Owner != "" {
		t.Fatal("summary leaked", detail)
	}
	receiver := testContext("receiver", authorization.Grants{MaterialsInbound: true})
	detail = must(f.s.Application(receiver, app.ID, Filter{}))(t)
	if detail.Application.SignatureID != "" || detail.Versions[0].SignatureID != "" {
		t.Fatal("signature reference leaked")
	}
	if _, _, err := f.s.Asset(receiver, app.SignatureID); !errors.Is(err, ErrMissing) {
		t.Fatalf("approval signature leaked %v", err)
	}
	active := true
	ctx := authorization.WithActor(context.Background(), authorization.Actor{ID: "warehouse", Grants: allGrants(), Valid: func() bool { return active }})
	active = false
	if _, err := f.s.Confirm(ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID}); !errors.Is(err, authorization.ErrDenied) {
		t.Fatal("stale actor", err)
	}
}

func TestApprovalAndTransferCompetition(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(map[bool]string{false: "sqlite", true: "postgres"}[pg], func(t *testing.T) {
			f := setup(t, pg)
			app := must(f.s.Submit(f.ctx, ApplicationInput{Mutation: operation(), Text: "并发审批"}))(t)
			results := make(chan error, 2)
			var wg sync.WaitGroup
			for i := 0; i < 2; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					_, err := f.s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"})
					results <- err
				}()
			}
			wg.Wait()
			close(results)
			success := 0
			for err := range results {
				if err == nil {
					success++
				} else if !errors.Is(err, ErrConflict) {
					t.Fatal(err)
				}
			}
			if success != 1 {
				t.Fatal("multiple approvals", success)
			}
			f.inbound(t, "5", Application{})
			out := f.outboundInput(t, "4")
			transfer := out
			transfer.Mutation = operation()
			transfer.Lines = append([]LineInput{}, out.Lines...)
			transfer.Lines[0].TargetCategoryID = f.scrap.ID
			results = make(chan error, 2)
			for kind, in := range map[string]DocumentInput{"outbound": out, "transfer": transfer} {
				wg.Add(1)
				go func(kind string, in DocumentInput) {
					defer wg.Done()
					_, err := f.s.Confirm(f.ctx, kind, in)
					results <- err
				}(kind, in)
			}
			wg.Wait()
			close(results)
			success = 0
			for err := range results {
				if err == nil {
					success++
				} else if !errors.Is(err, ErrConflict) && !errors.Is(err, ErrStock) {
					t.Fatal(err)
				}
			}
			if success != 1 || f.stock(t, f.normal.ID).Quantity != "1" {
				t.Fatal("stock competition failed")
			}
		})
	}
}

func TestFinalCommitFailureRollsBackLedgerAndCanRetry(t *testing.T) {
	f := setup(t, false)
	f.inbound(t, "5", Application{})
	in := f.outboundInput(t, "2")
	if _, err := f.s.db.Exec("CREATE TRIGGER materials_test_failure BEFORE INSERT ON materials_operations BEGIN SELECT RAISE(ABORT,'injected commit-stage failure'); END"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.Confirm(f.ctx, "outbound", in); err == nil {
		t.Fatal("failure not injected")
	}
	f.s = must(Open(f.s.db))(t)
	if f.stock(t, f.normal.ID).Quantity != "5" || must(f.s.Documents(f.ctx, "outbound", Filter{}))(t).Total != 0 {
		t.Fatal("partial stock/doc committed")
	}
	if moves := must(f.s.Movements(f.ctx, Filter{}))(t); moves.Total != 1 {
		t.Fatal("partial ledger", moves)
	}
	if _, err := f.s.db.Exec("DROP TRIGGER materials_test_failure"); err != nil {
		t.Fatal(err)
	}
	out := must(f.s.Confirm(f.ctx, "outbound", in))(t)
	if must(f.s.Confirm(f.ctx, "outbound", in))(t).ID != out.ID || f.stock(t, f.normal.ID).Quantity != "3" {
		t.Fatal("retry double-posted")
	}
}

func TestImagesOrientationTransparencyAndLimits(t *testing.T) {
	raw := imageBytes(color.NRGBA{R: 1, A: 17})
	normalized, _, err := normalizeImage(raw)
	if err != nil {
		t.Fatal(err)
	}
	im, err := png.Decode(bytes.NewReader(normalized))
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, alpha := im.At(0, 0).RGBA()
	if alpha != 0 {
		t.Fatal("transparent signature changed")
	}
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, image.NewRGBA(image.Rect(0, 0, 20, 10)), nil); err != nil {
		t.Fatal(err)
	}
	// Standard little-endian TIFF orientation=6 fixture, injected as APP1.
	exif := []byte{'E', 'x', 'i', 'f', 0, 0, 'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0}
	jpegData := encoded.Bytes()
	oriented := append([]byte{}, jpegData[:2]...)
	oriented = append(oriented, 0xff, 0xe1, 0, byte(len(exif)+2))
	oriented = append(oriented, exif...)
	oriented = append(oriented, jpegData[2:]...)
	normalized, _, err = normalizeImage(oriented)
	if err != nil {
		t.Fatal(err)
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(normalized))
	if err != nil || cfg.Width != 10 || cfg.Height != 20 {
		t.Fatal("EXIF orientation", cfg, err)
	}
	var huge bytes.Buffer
	if err := png.Encode(&huge, image.NewGray(image.Rect(0, 0, 5001, 4000))); err != nil {
		t.Fatal(err)
	}
	if _, _, err = normalizeImage(huge.Bytes()); err == nil {
		t.Fatal("over 20 megapixels")
	}
}

func TestExportLiteralTextAndFailureDoesNotPost(t *testing.T) {
	f := setup(t, false)
	f.item.Name = "=HYPERLINK(\"https://example.test\",\"x\")"
	f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
	f.inbound(t, "3", Application{})
	out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
	data, _, err := f.s.Export(f.ctx, out.ID)
	if err != nil {
		t.Fatal(err)
	}
	x := must(excelize.OpenReader(bytes.NewReader(data)))(t)
	defer x.Close()
	if must(x.GetCellFormula("出库单", "B5"))(t) != "" || must(x.GetCellValue("出库单", "B5"))(t) != f.item.Name {
		t.Fatal("formula executed")
	}
	// Corrupt only this isolated signature to exercise a real exporter failure.
	if _, err = f.s.db.Exec("UPDATE materials_assets SET data='' WHERE id=?", out.SignatureID); err != nil {
		t.Fatal(err)
	}
	if _, _, err = f.s.Export(f.ctx, out.ID); err == nil {
		t.Fatal("invalid signature export succeeded")
	}
	if f.stock(t, f.normal.ID).Quantity != "2" || must(f.s.Documents(f.ctx, "outbound", Filter{}))(t).Total != 1 {
		t.Fatal("export changed inventory")
	}
}
