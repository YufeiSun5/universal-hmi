package equipment

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"image"
	"image/png"
	"testing"
)

type memory struct {
	data  []byte
	fail  bool
	reads int
}

func (m *memory) LoadConfig(_ string, v any) error {
	m.reads++
	if len(m.data) == 0 {
		return nil
	}
	return json.Unmarshal(m.data, v)
}
func (m *memory) SaveConfig(_ string, v any) error {
	if m.fail {
		return errors.New("disk unavailable")
	}
	b, e := json.Marshal(v)
	m.data = b
	return e
}
func actor(st string, edit bool) context.Context {
	roles := []string{"viewer"}
	if edit {
		roles = []string{"engineer"}
	}
	return authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: roles, AllStations: edit, StationIDs: []string{st}}, StationID: func(n string) string { return n }, Valid: func() bool { return true }})
}
func TestStaticRegisterDoesNotInferOperationalStatus(t *testing.T) {
	s, err := Open(&memory{}, t.TempDir(), func() ([]string, error) { return []string{"A"}, nil })
	if err != nil {
		t.Fatal(err)
	}
	d, err := s.Save(actor("A", true), Device{Station: "A", Code: "P-static", Name: "pump", Category: "水泵"})
	if err != nil || d.Status != "" {
		t.Fatalf("new static record: %+v, %v", d, err)
	}
	d.Status = "maintenance"
	d, err = s.Save(actor("A", true), d)
	if err != nil {
		t.Fatal(err)
	}
	d.Status = ""
	d.Model = "Updated model"
	d, err = s.Save(actor("A", true), d)
	if err != nil || d.Status != "maintenance" {
		t.Fatalf("legacy status was overwritten: %+v, %v", d, err)
	}
}
func TestPersistenceScopeConflictAndPhotos(t *testing.T) {
	repo := &memory{}
	dir := t.TempDir()
	resolve := func() ([]string, error) { return []string{"A", "B"}, nil }
	s, e := Open(repo, dir, resolve)
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.Save(actor("A", true), Device{Station: "A", Code: "P-01", Name: "循环泵", Category: "水泵", Status: "active", Properties: []Property{{"功率", "30", "kW"}}})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Save(actor("A", false), d); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	if _, e = s.Get(actor("B", false), d.ID); !errors.Is(e, ErrMissing) {
		t.Fatal(e)
	}
	page, e := s.List(actor("B", false), Filter{Limit: 50})
	if e != nil || page.Total != 0 || len(page.Places) != 0 || page.Counts["all"] != 0 {
		t.Fatal(page, e)
	}
	stale := d
	d.Name = "一号循环泵"
	d, e = s.Save(actor("A", true), d)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Save(actor("A", true), stale); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	var photo bytes.Buffer
	png.Encode(&photo, image.NewRGBA(image.Rect(0, 0, 20, 20)))
	if _, e = s.AddPhoto(actor("A", true), d.ID, d.Revision, "bad.png", []byte("<svg>script</svg>")); e == nil {
		t.Fatal("accepted fake image")
	}
	d, e = s.AddPhoto(actor("A", true), d.ID, d.Revision, "photo.png", photo.Bytes())
	if e != nil || len(d.Photos) != 1 {
		t.Fatal(d, e)
	}
	p := d.Photos[0]
	if _, _, e = s.Photo(actor("B", false), d.ID, p.ID); !errors.Is(e, ErrMissing) {
		t.Fatal(e)
	}
	if _, _, e = s.Photo(actor("A", false), d.ID, "../../private"); !errors.Is(e, ErrMissing) {
		t.Fatal(e)
	}
	repo.fail = true
	d.Name = "must not persist"
	if _, e = s.Save(actor("A", true), d); e == nil {
		t.Fatal("write failure swallowed")
	}
	repo.fail = false
	reopened, e := Open(repo, dir, resolve)
	if e != nil {
		t.Fatal(e)
	}
	d, e = reopened.Get(actor("A", false), d.ID)
	if e != nil || d.Name != "一号循环泵" {
		t.Fatal(d, e)
	}
	_, b, e := reopened.Photo(actor("A", false), d.ID, p.ID)
	if e != nil || len(b) == 0 {
		t.Fatal(e)
	}
	page, e = reopened.List(actor("A", false), Filter{Limit: 50, Search: "P-01"})
	if e != nil || page.Total != 1 || page.Counts["active"] != 1 {
		t.Fatal(page, e)
	}
	d.Photos = []Photo{{ID: "forged", Name: "bad"}}
	d, e = reopened.Save(actor("A", true), d)
	if e != nil || d.Photos[0].ID != p.ID {
		t.Fatal(d, e)
	}
	d, e = reopened.RemovePhoto(actor("A", true), d.ID, p.ID, d.Revision)
	if e != nil || len(d.Photos) != 0 {
		t.Fatal(d, e)
	}
	if _, _, e = reopened.Photo(actor("A", false), d.ID, p.ID); !errors.Is(e, ErrMissing) {
		t.Fatal(e)
	}
	for _, bad := range []Device{{Station: "missing", Code: "P-02", Name: "x", Category: "水泵", Status: "active"}, {Station: "A", Code: "P-01", Name: "duplicate", Category: "水泵", Status: "active"}, {Station: "A", Code: "P-02", Name: "x", Category: "水泵", Status: "active", Installed: "yesterday"}} {
		if _, e = s.Save(actor("A", true), bad); e == nil {
			t.Fatal("accepted invalid", bad)
		}
	}
	revoked := authorization.WithActor(context.Background(), authorization.Actor{Valid: func() bool { return false }})
	if _, e = s.List(revoked, Filter{Limit: 50}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
}
