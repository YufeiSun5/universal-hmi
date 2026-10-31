package process

import (
	"encoding/json"
	"errors"
	"testing"
)

func TestBackgroundContract(t *testing.T) {
	one, angle := 1.0, 90.0
	for _, b := range []*Background{{Type: "solid", Color: "#123456", Opacity: &one}, {Type: "linear", Color: "#123456", EndColor: "#abcdef", Angle: &angle, Opacity: &one}, {Type: "image", Color: "#123456", Opacity: &one, Image: "picture", Fit: "contain"}} {
		d := document()
		d.Background = b
		if b.Type == "image" {
			d.Assets["picture"] = embedded(t)
		}
		s, e := Open(t.TempDir())
		if e != nil {
			t.Fatal(e)
		}
		saved, e := s.Save(d)
		if e != nil {
			t.Fatal(e)
		}
		got, e := s.Get(saved.ID)
		if e != nil || got.Background == nil || got.Background.Type != b.Type {
			t.Fatal(got, e)
		}
	}
	for _, raw := range []string{`{"type":"solid","color":"#123456"}`, `{"type":"solid","color":"#123456","opacity":1,"angle":0}`, `{"type":"linear","color":"#123456","opacity":1,"end_color":"#abcdef"}`, `{"type":"image","color":"#123456","opacity":1,"image":"picture","fit":"contain","extra":0}`} {
		var b Background
		if json.Unmarshal([]byte(raw), &b) == nil {
			t.Fatal(raw)
		}
	}
	d := document()
	d.Background = &Background{Type: "image", Color: "#123456", Opacity: &one, Image: "https://example.com/a.png", Fit: "cover"}
	if !errors.Is(Validate(d), ErrInvalid) {
		t.Fatal("remote accepted")
	}
	d.Background = &Background{Type: "linear", Color: "#123456", EndColor: "#abcdef", Opacity: &one, Angle: func() *float64 { v := 361.0; return &v }()}
	if !errors.Is(Validate(d), ErrInvalid) {
		t.Fatal("angle accepted")
	}
	d.Background = &Background{Type: "solid", Color: "#123456", Opacity: &one}
	d.Kind = "gis"
	if !errors.Is(Validate(d), ErrInvalid) {
		t.Fatal("GIS accepted")
	}
}
func TestBackgroundSharedInheritance(t *testing.T) {
	one := 1.0
	s, e := Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	public := document()
	public.ID = "public-background"
	public.Station = ""
	public.Background = &Background{Type: "image", Color: "#123456", Opacity: &one, Image: "picture", Fit: "cover"}
	public.Assets["picture"] = embedded(t)
	public, e = s.Save(public)
	if e != nil {
		t.Fatal(e)
	}
	instance := document()
	instance.ID = "background-instance"
	instance.TemplateID = public.ID
	instance.TemplateRevision = public.Revision
	instance, e = s.Save(instance)
	if e != nil {
		t.Fatal(e)
	}
	if instance.Background == nil || len(instance.Assets) != 1 {
		t.Fatal("missing inheritance")
	}
	if _, e = s.Save(instance); !errors.Is(e, ErrInvalid) {
		t.Fatal("override accepted", e)
	}
	public.Background.Fit = "fill"
	public, e = s.Save(public)
	if e != nil {
		t.Fatal(e)
	}
	instance, e = s.Get(instance.ID)
	if e != nil || instance.Background.Fit != "fill" {
		t.Fatal("not updated", e)
	}
}
