package process

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

func TestImageFilesMigrateScreensAndMaterialsWithoutChangingAPI(t *testing.T) {
	for _, database := range []bool{false, true} {
		t.Run(map[bool]string{false: "files", true: "document-store"}[database], func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, "screens")
			os.MkdirAll(filepath.Join(dir, "materials"), 0700)
			var docs DocumentStore
			if database {
				db, e := persistence.Open(filepath.Join(root, "project.sqlite"), "")
				if e != nil {
					t.Fatal(e)
				}
				defer db.Close()
				docs, e = persistence.NewDocuments(db)
				if e != nil {
					t.Fatal(e)
				}
			}
			m := transparentMaterial(t)
			m.Width = 2
			m.Height = 2
			m.Revision = 7
			d := document()
			d.Revision = 9
			d.Nodes = []Node{element("picture", "image")}
			d.Nodes[0].Image = "original"
			d.Assets = map[string]Asset{"original": m.Asset}
			write := func(kind, id string, b []byte) {
				t.Helper()
				if docs != nil {
					if e := docs.Save(kind, id, b); e != nil {
						t.Fatal(e)
					}
				} else {
					folder := dir
					if kind == "materials" {
						folder = filepath.Join(dir, kind)
					}
					if e := os.WriteFile(filepath.Join(folder, id+".json"), b, 0600); e != nil {
						t.Fatal(e)
					}
				}
			}
			raw, _ := json.Marshal(d)
			write("screens", d.ID, raw)
			raw, _ = json.Marshal(m)
			write("materials", m.ID, raw)
			s, e := OpenDocuments(dir, docs)
			if e != nil {
				t.Fatal(e)
			}
			got, e := s.Get(d.ID)
			if e != nil || got.Revision != 9 || got.Assets["original"].Data != m.Asset.Data {
				t.Fatal("screen changed", e)
			}
			asset, e := s.GetMaterial(m.ID)
			if e != nil || asset.Revision != 7 || asset.Asset.Data != m.Asset.Data {
				t.Fatal("material changed", e)
			}
			stored, e := s.storedBytes(dir, d.ID, MaxDocumentBytes)
			if e != nil || bytes.Contains(stored, []byte(m.Asset.Data)) || !bytes.Contains(stored, []byte("fileblob-v1")) {
				t.Fatal("inline image persisted", e)
			}
			// A user cannot submit a reference to another user's protected image.
			var persisted Document
			if e = json.Unmarshal(stored, &persisted); e != nil {
				t.Fatal(e)
			}
			if _, e = s.Save(persisted); e == nil {
				t.Fatal("external file reference accepted from client")
			}
			if _, e = OpenDocuments(dir, docs); e != nil {
				t.Fatal(e)
			}
			repeat, e := s.storedBytes(dir, d.ID, MaxDocumentBytes)
			if e != nil || !bytes.Equal(stored, repeat) {
				t.Fatal("restart changed stored document", e)
			}
			ref, e := objectstore.Parse([]byte(persisted.Assets["original"].Data))
			if e != nil {
				t.Fatal(e)
			}
			if e = os.Remove(filepath.Join(root, "objects", filepath.FromSlash(ref.Key))); e != nil {
				t.Fatal(e)
			}
			if _, e = s.Get(d.ID); e == nil {
				t.Fatal("missing file returned a usable screen")
			}
			// The catalog describes stored documents, not their render payloads.
			// Image I/O must not make every directory/navigation request fail.
			meta, e := s.GetSummary(d.ID)
			if e != nil || meta.ID != d.ID || meta.Station != d.Station || meta.Revision != 9 {
				t.Fatal("metadata depends on image availability", meta, e)
			}
			listed, e := s.ListAll()
			if e != nil || len(listed) != 1 || listed[0] != meta {
				t.Fatal("catalog depends on image availability", listed, e)
			}
			if _, e = OpenDocuments(dir, docs); e == nil {
				t.Fatal("incomplete restore accepted")
			}
		})
	}
}

func TestReferencedImagesCannotExceedDocumentMemoryBudget(t *testing.T) {
	root := t.TempDir()
	s, e := Open(filepath.Join(root, "screens"))
	if e != nil {
		t.Fatal(e)
	}
	ref, e := s.files.Put(context.Background(), bytes.Repeat([]byte{1}, MaxImageBytes))
	if e != nil {
		t.Fatal(e)
	}
	assets := map[string]Asset{}
	for i := 0; i < 4; i++ {
		assets[fmt.Sprintf("image-%d", i)] = Asset{Name: "image.png", MIME: "image/png", Data: string(ref)}
	}
	raw, _ := json.Marshal(map[string]any{"assets": assets})
	if _, e = s.imageData(raw, true, MaxDocumentBytes); !errors.Is(e, ErrInvalid) {
		t.Fatalf("oversized expansion accepted: %v", e)
	}
	for i := 4; i < 65; i++ {
		assets[fmt.Sprintf("image-%d", i)] = Asset{Name: "image.png", MIME: "image/png", Data: string(ref)}
	}
	raw, _ = json.Marshal(map[string]any{"assets": assets})
	if _, e = s.imageData(raw, true, MaxDocumentBytes); !errors.Is(e, ErrInvalid) {
		t.Fatalf("image count limit not checked: %v", e)
	}
}
