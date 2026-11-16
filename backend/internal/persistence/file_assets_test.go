package persistence_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/materials"
	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/totalreports"
	"github.com/xuri/excelize/v2"
)

func TestPostgreSQLLegacyBusinessFiles(t *testing.T) {
	dsn := os.Getenv("HMI_FILES_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("isolated PostgreSQL DSN not supplied")
	}
	admin, e := persistence.Open("", dsn)
	must(t, e)
	defer admin.Close()
	schema := fmt.Sprintf("asset_files_%d", time.Now().UnixNano())
	_, e = admin.Exec("CREATE SCHEMA " + schema)
	must(t, e)
	defer func() {
		_, e := admin.Exec("DROP SCHEMA " + schema + " CASCADE")
		if e != nil {
			t.Error(e)
		}
	}()
	u, e := url.Parse(dsn)
	must(t, e)
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	db, e := persistence.Open("", u.String())
	must(t, e)
	defer db.Close()
	var active string
	must(t, db.QueryRow("SELECT current_schema()").Scan(&active))
	if active != schema {
		t.Fatal("wrong schema")
	}
	root := t.TempDir()
	files, e := objectstore.Open(filepath.Join(root, "objects"))
	must(t, e)
	defer files.Close()
	_, e = materials.Open(db, files)
	must(t, e)
	_, e = totalreports.Open(db, files)
	must(t, e)
	docs, e := persistence.NewDocuments(db)
	must(t, e)
	var picture bytes.Buffer
	must(t, png.Encode(&picture, image.NewNRGBA(image.Rect(0, 0, 3, 3))))
	encoded := base64.StdEncoding.EncodeToString(picture.Bytes())
	_, e = db.Exec("INSERT INTO materials_assets(id,owner_id,kind,body,data) VALUES(?,?,?,?,?)", "legacy-receipt", "owner", "receipt", `{"id":"legacy-receipt","name":"legacy.png","kind":"receipt","mime":"image/png"}`, encoded)
	must(t, e)
	d := process.Document{SchemaVersion: 1, ID: "legacy-screen", Name: "Legacy", Station: "A", Width: 800, Height: 600, Revision: 11, Nodes: []process.Node{}, Assets: map[string]process.Asset{"picture": {Name: "legacy.png", MIME: "image/png", Data: encoded}}}
	d.Nodes = []process.Node{{ID: "picture-node", Kind: "image", X: 20, Y: 20, Width: 100, Height: 100, Color: "#2563eb", Fill: "none", StrokeWidth: 4, FontSize: 20, Image: "picture"}}
	raw, e := json.Marshal(d)
	must(t, e)
	must(t, docs.Save("screens", d.ID, raw))
	m := process.Material{SchemaVersion: 1, ID: "legacy-material", Name: "Legacy", Width: 3, Height: 3, Revision: 4, Asset: d.Assets["picture"]}
	raw, e = json.Marshal(m)
	must(t, e)
	must(t, docs.Save("materials", m.ID, raw))
	x := excelize.NewFile()
	must(t, x.SetCellValue("Sheet1", "A1", "preserved"))
	book, e := x.WriteToBuffer()
	must(t, e)
	x.Close()
	hashed, _ := json.Marshal(book.Bytes())
	bookID := fmt.Sprintf("%x", sha256.Sum256(hashed))
	_, e = db.Exec("INSERT INTO total_report_originals(id,data) VALUES(?,?)", bookID, book.Bytes())
	must(t, e)
	for range 2 {
		_, e = materials.Open(db, files)
		must(t, e)
		_, e = totalreports.Open(db, files)
		must(t, e)
		s, e := process.OpenWithFiles(filepath.Join(root, "screens"), docs, files)
		must(t, e)
		loaded, e := s.Get(d.ID)
		must(t, e)
		if loaded.Revision != 11 || loaded.Assets["picture"].Data != encoded {
			t.Fatal("screen changed")
		}
		material, e := s.GetMaterial(m.ID)
		must(t, e)
		if material.Revision != 4 || material.Asset.Data != encoded {
			t.Fatal("material changed")
		}
		stored, e := docs.Load("screens", d.ID)
		must(t, e)
		if strings.Contains(string(stored), encoded) {
			t.Fatal("inline screen picture remains")
		}
		var ref string
		must(t, db.QueryRow("SELECT data FROM materials_assets WHERE id=?", "legacy-receipt").Scan(&ref))
		payload, e := files.Get(context.Background(), []byte(ref))
		must(t, e)
		if !bytes.Equal(payload, picture.Bytes()) {
			t.Fatal("receipt changed")
		}
		var reference []byte
		must(t, db.QueryRow("SELECT data FROM total_report_originals WHERE id=?", bookID).Scan(&reference))
		payload, e = files.Get(context.Background(), reference)
		must(t, e)
		if !bytes.Equal(payload, book.Bytes()) {
			t.Fatal("workbook changed")
		}
	}
}
