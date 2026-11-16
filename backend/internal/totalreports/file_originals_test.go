package totalreports

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/objectstore"
	"github.com/xuri/excelize/v2"
)

func TestOriginalFileMigrationPreservesWorkbookBytes(t *testing.T) {
	s, _ := fixture(t)
	x, e := excelize.OpenReader(bytes.NewReader(preservationWorkbook(t)))
	if e != nil {
		t.Fatal(e)
	}
	var picture bytes.Buffer
	if e = png.Encode(&picture, image.NewNRGBA(image.Rect(0, 0, 3, 3))); e != nil {
		t.Fatal(e)
	}
	if e = x.AddPictureFromBytes(preservationSheet, "A1", &excelize.Picture{Extension: ".png", File: picture.Bytes()}); e != nil {
		t.Fatal(e)
	}
	book, e := x.WriteToBuffer()
	if e != nil {
		t.Fatal(e)
	}
	x.Close()
	data := book.Bytes()
	id := digest(data)
	if _, e := s.db.Exec("INSERT INTO total_report_originals(id,data) VALUES(?,?)", id, data); e != nil {
		t.Fatal(e)
	}
	broken, e := objectstore.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	broken.Close()
	if _, e = Open(s.db, broken); e == nil {
		t.Fatal("unavailable file store accepted")
	}
	var actual []byte
	if e = s.db.QueryRow("SELECT data FROM total_report_originals WHERE id=?", id).Scan(&actual); e != nil || !bytes.Equal(actual, data) {
		t.Fatal("failed migration lost workbook", e)
	}
	s, e = Open(s.db, s.files)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.db.QueryRow("SELECT data FROM total_report_originals WHERE id=?", id).Scan(&actual); e != nil {
		t.Fatal(e)
	}
	if _, e = objectstore.Parse(actual); e != nil {
		t.Fatal("workbook bytes still in database", e)
	}
	got, e := s.loadOriginal(context.Background(), id)
	if e != nil || !bytes.Equal(data, got) {
		t.Fatal("workbook changed", e)
	}
	if _, e = Open(s.db, s.files); e != nil {
		t.Fatal(e)
	}
}
