package materials

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"io"
	"strconv"
	"strings"
	"testing"

	"github.com/xuri/excelize/v2"
)

func TestExportLongFieldsRemainCompleteAndFitPrintedWidth(t *testing.T) {
	f := setup(t, false)
	f.item.Name = strings.Repeat("长物料名称", 35)
	f.item.Specification = strings.Repeat("WWW 技术abc ", 15)
	f.item = must(f.s.SaveItem(f.ctx, ItemInput{Mutation: operation(), Item: f.item}))(t)
	f.inbound(t, "2", Application{})
	input := f.outboundInput(t, "1")
	input.Purpose = strings.Repeat("用途说明", 220)
	input.Notes = strings.Repeat("完整备注", 450)
	out := must(f.s.Confirm(f.ctx, "outbound", input))(t)
	data, _, e := f.s.Export(f.ctx, out.ID)
	if e != nil {
		t.Fatal(e)
	}
	book := must(excelize.OpenReader(bytes.NewReader(data)))(t)
	defer book.Close()
	rows := must(book.GetRows("出库单"))(t)
	columns := make([]string, 9)
	for i, row := range rows {
		if h := must(book.GetRowHeight("出库单", i+1))(t); h > 188 {
			t.Fatalf("row %d can clip or cross page: %f", i+1, h)
		}
		for col, value := range row {
			if col < len(columns) {
				columns[col] += value
			}
		}
	}
	for _, part := range []struct {
		Column int
		Value  string
	}{{1, f.item.Name}, {2, f.item.Specification}, {0, input.Purpose}, {0, input.Notes}} {
		if !strings.Contains(columns[part.Column], part.Value) {
			t.Fatalf("lost text in column %d", part.Column)
		}
	}
	props := must(book.GetSheetProps("出库单"))(t)
	if props.FitToPage == nil || !*props.FitToPage {
		t.Fatal("Excel fit-to-page mode must be enabled explicitly")
	}
	layout := must(book.GetPageLayout("出库单"))(t)
	if layout.FitToWidth == nil || *layout.FitToWidth != 1 || layout.FitToHeight == nil || *layout.FitToHeight != 0 || layout.Orientation == nil || *layout.Orientation != "portrait" {
		t.Fatal("A4 portrait pagination changed")
	}
	anchors := must(book.GetPictureCells("出库单"))(t)
	if len(anchors) != 1 || !strings.HasPrefix(anchors[0], "F") {
		t.Fatalf("signature not at right footer: %v", anchors)
	}
	pics := must(book.GetPictures("出库单", anchors[0]))(t)
	_, original, e := f.s.Asset(f.ctx, out.SignatureID)
	if e != nil {
		t.Fatal(e)
	}
	if len(pics) != 1 || !bytes.Equal(pics[0].File, original) {
		t.Fatal("layout modified signature source")
	}
	// Check drawing dimensions, not just that an image exists in the archive.
	archive := must(zip.NewReader(bytes.NewReader(data), int64(len(data))))(t)
	dimensions := 0
	for _, file := range archive.File {
		if !strings.HasPrefix(file.Name, "xl/drawings/drawing") || !strings.HasSuffix(file.Name, ".xml") {
			continue
		}
		r := must(file.Open())(t)
		decoder := xml.NewDecoder(r)
		for {
			token, e := decoder.Token()
			if e == io.EOF {
				break
			}
			if e != nil {
				t.Fatal(e)
			}
			if element, ok := token.(xml.StartElement); ok && element.Name.Local == "ext" {
				for _, a := range element.Attr {
					if a.Name.Local == "cx" || a.Name.Local == "cy" {
						v := must(strconv.ParseInt(a.Value, 10, 64))(t)
						limit := int64(120 * 9525)
						if a.Name.Local == "cy" {
							limit = 40 * 9525
						}
						if v > limit+1 {
							t.Fatalf("signature too large: %s=%d", a.Name.Local, v)
						}
						dimensions++
					}
				}
			}
		}
		r.Close()
	}
	if dimensions != 2 {
		t.Fatalf("signature geometry not checked: %d", dimensions)
	}
	if f.stock(t, f.normal.ID).Quantity != "1" {
		t.Fatal("export altered stock")
	}
}

func TestExportContinuationPreservesWhitespaceAndWordWrapping(t *testing.T) {
	for _, value := range []string{"", strings.Repeat("abcdefghijkl ", 30), strings.Repeat("中文宽字符与emoji🚀 ", 30), "第一行\r\n第二行\n\n" + strings.Repeat("MWW a\t", 60), strings.Repeat("e\u0301", 500)} {
		parts := exportTextParts(value, 14, 12)
		var combined strings.Builder
		for _, part := range parts {
			combined.WriteString(part.Text)
			if part.Lines < 1 || part.Lines > 12 {
				t.Fatalf("unbounded print row: %+v", part)
			}
		}
		if combined.String() != value {
			t.Fatal("continuation lost or rewrote text")
		}
	}
	parts := exportTextParts(strings.Repeat("abcdefghijkl ", 12), 14, 12)
	if parts[0].Lines < 12 {
		t.Fatal("word-wrap underestimated line height")
	}
}
