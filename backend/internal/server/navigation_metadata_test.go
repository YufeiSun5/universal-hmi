package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/navigation"
	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

type navigationCountingDocuments struct {
	process.DocumentStore
	loads map[string]int
}

func (d *navigationCountingDocuments) Load(kind, id string) ([]byte, error) {
	d.loads[id]++
	return d.DocumentStore.Load(kind, id)
}

func TestNavigationReadsMetadataOnceWithoutImageIO(t *testing.T) {
	root := t.TempDir()
	db, err := storage.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	persisted, err := persistence.NewDocuments(db.DB)
	if err != nil {
		t.Fatal(err)
	}
	docs := &navigationCountingDocuments{DocumentStore: persisted, loads: map[string]int{}}
	files, err := objectstore.Open(filepath.Join(root, "objects"))
	if err != nil {
		t.Fatal(err)
	}
	defer files.Close()
	screens, err := process.OpenWithFiles(filepath.Join(root, "screens"), docs, files)
	if err != nil {
		t.Fatal(err)
	}
	var pngBytes bytes.Buffer
	if err = png.Encode(&pngBytes, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"A", "B", "shared"} {
		d := process.Document{SchemaVersion: 1, ID: id, Name: id, Station: id, Width: 1600, Height: 900,
			Nodes:  []process.Node{{ID: "picture", Kind: "image", Image: "image", X: 20, Y: 20, Width: 100, Height: 100, Color: "#2563eb", Fill: "none", StrokeWidth: 4, FontSize: 20}},
			Assets: map[string]process.Asset{"image": {Name: "fixture.png", MIME: "image/png", Data: base64.StdEncoding.EncodeToString(pngBytes.Bytes())}}}
		if id == "shared" {
			d.Station = ""
		}
		if _, err = screens.Save(d); err != nil {
			t.Fatal(err)
		}
	}
	config := navigation.Config{Enabled: true, Revision: 1}
	for i := 0; i < 64; i++ {
		config.Nodes = append(config.Nodes, navigation.Node{ID: fmt.Sprintf("a-%d", i), Label: "A", ScreenID: "A"})
	}
	for _, id := range []string{"B", "shared", "missing"} {
		config.Nodes = append(config.Nodes, navigation.Node{ID: id, Label: id, ScreenID: id})
	}
	if err = db.SaveConfig("page_navigation", config); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	registerNavigation(mux, db, screens)
	// Any image access now fails. Navigation must still expose only the saved
	// targets granted to this account; a full document read must fail honestly.
	if err = files.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = screens.Get("A"); err == nil {
		t.Fatal("fixture did not prevent image reads")
	}
	docs.loads = map[string]int{}
	actor := authorization.Actor{ID: "reader", Valid: func() bool { return true },
		Grants:    authorization.Grants{StationIDs: []string{"A"}, ScreenIDs: []string{"shared"}},
		StationID: func(name string) string { return name }}
	read := func(a authorization.Actor) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/v1/navigation", nil)
		r = r.WithContext(authorization.WithActor(r.Context(), a))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		return w
	}
	w := read(actor)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var result navigation.Config
	if err = json.Unmarshal(w.Body.Bytes(), &result); err != nil || len(result.Nodes) != 65 || result.Nodes[64].ScreenID != "shared" {
		t.Fatal("authorized targets lost or unauthorized targets exposed", result, err)
	}
	for _, id := range []string{"A", "B", "shared", "missing"} {
		if docs.loads[id] != 1 {
			t.Fatalf("screen %s loaded %d times in one request", id, docs.loads[id])
		}
	}
	checks := 0
	actor.Valid = func() bool { checks++; return checks == 1 }
	if revoked := read(actor); revoked.Code != 403 {
		t.Fatal("revocation during navigation read accepted", revoked.Code)
	}
}
