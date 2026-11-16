package materials

import (
	"bytes"
	"context"
	"encoding/base64"
	"image/color"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
)

func TestAssetFileMigrationPreservesHistoryAndRetry(t *testing.T) {
	for _, pg := range []bool{false, true} {
		t.Run(map[bool]string{false: "sqlite", true: "postgres"}[pg], func(t *testing.T) {
			f := setup(t, pg)
			f.inbound(t, "3", Application{})
			out := must(f.s.Confirm(f.ctx, "outbound", f.outboundInput(t, "1")))(t)
			_, original, e := f.s.loadAsset(f.s.db, out.SignatureID)
			if e != nil {
				t.Fatal(e)
			}
			// Simulate a v91 persisted signature, with its historical document intact.
			legacy := base64.StdEncoding.EncodeToString(original)
			if _, e = f.s.db.Exec("UPDATE materials_assets SET data=? WHERE id=?", legacy, out.SignatureID); e != nil {
				t.Fatal(e)
			}
			broken := must(objectstore.Open(t.TempDir()))(t)
			broken.Close()
			if _, e = Open(f.s.db, broken); e == nil {
				t.Fatal("migration with unavailable store succeeded")
			}
			var after string
			if e = f.s.db.QueryRow("SELECT data FROM materials_assets WHERE id=?", out.SignatureID).Scan(&after); e != nil || after != legacy {
				t.Fatal("legacy bytes lost on failure", e)
			}
			f.s = must(Open(f.s.db, f.s.files))(t)
			if e = f.s.db.QueryRow("SELECT data FROM materials_assets WHERE id=?", out.SignatureID).Scan(&after); e != nil {
				t.Fatal(e)
			}
			if _, e = objectstore.Parse([]byte(after)); e != nil || after == legacy {
				t.Fatal("database still contains payload", e)
			}
			_, got, e := f.s.loadAsset(f.s.db, out.SignatureID)
			if e != nil || !bytes.Equal(got, original) {
				t.Fatal("signature changed", e)
			}
			sign(t, f.s, f.ctx, color.NRGBA{R: 177, A: 255})
			if _, _, e = f.s.Export(f.ctx, out.ID); e != nil {
				t.Fatal("historical signature export after replacing current signature", e)
			}
			if f.stock(t, f.normal.ID).Quantity != "2" {
				t.Fatal("migration changed inventory")
			}
			must(Open(f.s.db, f.s.files))(t)
			if e = f.s.db.QueryRow("SELECT data FROM materials_assets WHERE id=?", out.SignatureID).Scan(&after); e != nil {
				t.Fatal(e)
			}
			if _, e = f.s.files.Get(context.Background(), []byte(after)); e != nil {
				t.Fatal(e)
			}
		})
	}
}
