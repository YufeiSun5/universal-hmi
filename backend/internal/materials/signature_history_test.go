package materials

import (
	"bytes"
	"errors"
	"image/color"
	"sync"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestSignatureLifecycleKeepsSignedHistory(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			f.inbound(t, "3", Application{})
			out := must(s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
			_, original, e := s.Asset(f.ctx, f.sig.AssetID)
			if e != nil {
				t.Fatal(e)
			}
			changed := sign(t, s, f.ctx, color.NRGBA{G: 240, A: 255})
			deletion := SignatureInput{Mutation: operation(), Signature: Signature{Version: changed.Version}, Delete: true}
			deleted := must(s.SaveSignature(f.ctx, deletion))(t)
			if deleted.AssetID != "" || deleted.Version != changed.Version+1 {
				t.Fatalf("delete result %+v", deleted)
			}
			if got := must(s.Signature(f.ctx))(t); got != deleted {
				t.Fatalf("current %+v", got)
			}
			if _, e := s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")); !errors.Is(e, ErrSignature) {
				t.Fatalf("deleted outbound: %v", e)
			}
			requestor := testContext("requestor", allGrants())
			app := must(s.Submit(requestor, ApplicationInput{Mutation: operation(), Text: "需要审批的申请"}))(t)
			if _, e := s.Approve(f.ctx, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "approved"}); !errors.Is(e, ErrSignature) {
				t.Fatalf("deleted approval: %v", e)
			}
			ret := DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: deleted.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, Quantity: "1", TargetCategoryID: f.normal.ID}}}
			if _, e := s.Confirm(f.ctx, "return", ret); !errors.Is(e, ErrSignature) {
				t.Fatalf("deleted return: %v", e)
			}
			history := must(s.SignatureHistory(f.ctx, Filter{Limit: 2}))(t)
			if history.Total != 3 || len(history.Items) != 2 || history.Items[0].Action != "deleted" || history.Items[0].AssetID != "" || history.Items[1].AssetID != changed.AssetID {
				t.Fatalf("history %+v", history)
			}
			earlier := must(s.SignatureHistory(f.ctx, Filter{Offset: 2, Limit: 2}))(t)
			if len(earlier.Items) != 1 || earlier.Items[0].AssetID != f.sig.AssetID || earlier.Items[0].Action != "created" {
				t.Fatalf("earlier %+v", earlier)
			}
			if other := must(s.SignatureHistory(requestor, Filter{}))(t); other.Total != 0 {
				t.Fatal("other user's history leaked")
			}
			personal := testContext("warehouse", authorization.Grants{})
			// Personal signature management does not imply warehouse business grants.
			if h := must(s.SignatureHistory(personal, Filter{}))(t); h.Total != 3 {
				t.Fatal("personal history unexpectedly needs business permission")
			}
			_, retained, e := s.Asset(f.ctx, f.sig.AssetID)
			if e != nil || !bytes.Equal(original, retained) {
				t.Fatalf("old asset changed %v", e)
			}
			detail := must(s.Document(f.ctx, out.ID, Filter{}))(t)
			if detail.Document.SignatureID != f.sig.AssetID || detail.Document.KnownAmount != out.KnownAmount {
				t.Fatal("signed outbound drift")
			}
			restored := sign(t, s, f.ctx, color.NRGBA{B: 180, A: 255})
			if restored.Version != deleted.Version+1 {
				t.Fatal("version reused after deletion")
			}
			if replay := must(s.SaveSignature(f.ctx, deletion))(t); replay != deleted {
				t.Fatal("delete replay changed")
			}
			if current := must(s.Signature(f.ctx))(t); current != restored {
				t.Fatal("delete replay deleted newer signature")
			}
			deletion.OperationID = id()
			if _, e := s.SaveSignature(f.ctx, deletion); !errors.Is(e, ErrConflict) {
				t.Fatalf("stale delete %v", e)
			}
			must(Open(s.db))(t)
			if current := must(s.Signature(f.ctx))(t); current != restored {
				t.Fatal("restart drift")
			}
		})
	}
}

func TestSignatureConcurrentChangesAndMigration(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			s := testService(t, pg)
			ctx := testContext("personal", authorization.Grants{})
			first := sign(t, s, ctx, color.NRGBA{R: 80, A: 255})
			asset := must(s.Upload(ctx, AssetInput{Mutation: operation(), Name: "next.png", Kind: "signature", Data: imageBytes(color.NRGBA{B: 90, A: 255})}))(t)
			other := testContext("other", authorization.Grants{})
			if _, e := s.SaveSignature(other, SignatureInput{Mutation: operation(), Signature: Signature{AssetID: asset.ID}}); !errors.Is(e, authorization.ErrDenied) {
				t.Fatalf("foreign signature %v", e)
			}
			if _, _, e := s.Asset(other, first.AssetID); !errors.Is(e, ErrMissing) {
				t.Fatalf("foreign history asset %v", e)
			}
			if _, e := s.SaveSignature(ctx, SignatureInput{Mutation: operation(), Signature: first, Delete: true}); e == nil {
				t.Fatal("delete with replacement accepted")
			}
			secondService := independentService(t, s)
			var wg sync.WaitGroup
			results := make(chan error, 2)
			wg.Add(2)
			go func() {
				defer wg.Done()
				_, e := s.SaveSignature(ctx, SignatureInput{Mutation: operation(), Signature: Signature{Version: first.Version}, Delete: true})
				results <- e
			}()
			go func() {
				defer wg.Done()
				_, e := secondService.SaveSignature(ctx, SignatureInput{Mutation: operation(), Signature: Signature{AssetID: asset.ID, Version: first.Version}})
				results <- e
			}()
			wg.Wait()
			close(results)
			success, conflict := 0, 0
			for e := range results {
				if e == nil {
					success++
				} else if errors.Is(e, ErrConflict) {
					conflict++
				} else {
					t.Fatal(e)
				}
			}
			if success != 1 || conflict != 1 {
				t.Fatalf("concurrent update/delete: %d/%d", success, conflict)
			}
			if h := must(s.SignatureHistory(ctx, Filter{}))(t); h.Total != 2 {
				t.Fatalf("concurrent history %+v", h)
			}
			// Simulate a pre-history current signature, then repeatedly initialize.
			_, e := s.db.Exec("INSERT INTO materials_signatures(user_id,asset_id,version) VALUES(?,?,?)", "legacy", first.AssetID, 7)
			if e != nil {
				t.Fatal(e)
			}
			must(Open(s.db))(t)
			must(Open(s.db))(t)
			legacy := testContext("legacy", authorization.Grants{})
			h := must(s.SignatureHistory(legacy, Filter{}))(t)
			if h.Total != 1 || h.Items[0].Version != 7 || h.Items[0].Created != "" || h.Items[0].Action != "migrated" {
				t.Fatalf("migration %+v", h)
			}
			deleted := must(s.SaveSignature(legacy, SignatureInput{Mutation: operation(), Signature: Signature{Version: 7}, Delete: true}))(t)
			must(Open(s.db))(t)
			if current := must(s.Signature(legacy))(t); current != deleted || current.AssetID != "" {
				t.Fatal("startup resurrected deleted signature")
			}
		})
	}
}
