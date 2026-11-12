package totalreports

import (
	"archive/zip"
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestCalculationCacheRemovalPreservesWorkbookParts(t *testing.T) {
	parts := map[string]string{
		"[Content_Types].xml":        `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="worksheet"/></Types>`,
		"xl/_rels/workbook.xml.rels": `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId8" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" Target="calcChain.xml"></Relationship><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>`,
		"xl/calcChain.xml":           `<calcChain><c r="B2" i="99"/></calcChain>`,
		"xl/worksheets/sheet1.xml":   `<worksheet><sheetData><row r="2"><c r="B2"><f>SUM(A1:A2)</f><v>7</v></c></row></sheetData></worksheet>`,
		"xl/styles.xml":              `<styleSheet><fonts count="1"/></styleSheet>`,
	}
	var input bytes.Buffer
	w := zip.NewWriter(&input)
	for name, value := range parts {
		f, _ := w.Create(name)
		f.Write([]byte(value))
	}
	w.Close()
	out, err := withoutCalculationChain(input.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	r, err := zip.NewReader(bytes.NewReader(out), int64(len(out)))
	if err != nil {
		t.Fatal(err)
	}
	if len(r.File) != len(parts)-1 {
		t.Fatal("unexpected removed part")
	}
	for _, f := range r.File {
		stream, _ := f.Open()
		b, _ := io.ReadAll(stream)
		stream.Close()
		if strings.Contains(f.Name, "calcChain") || strings.Contains(string(b), "calcChain") {
			t.Fatal("stale reference", f.Name)
		}
		if f.Name == "xl/worksheets/sheet1.xml" || f.Name == "xl/styles.xml" {
			if string(b) != parts[f.Name] {
				t.Fatal("formula or style changed", f.Name)
			}
		}
	}
	if _, err = removeChainReference([]byte("<broken>")); err == nil {
		t.Fatal("malformed package reference silently accepted")
	}
}
