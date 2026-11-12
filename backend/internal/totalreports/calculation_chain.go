package totalreports

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"io"
)

// Excel rebuilds this optional cache on open (Export requests full calculation).
// Excelize can retain inherited sheet IDs from deleted auxiliary sheets in the
// original chain, which makes Excel reject an otherwise valid exported file.
// Remove only the cache and its package references, preserving all formula XML.
func withoutCalculationChain(data []byte) ([]byte, error) {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	w := zip.NewWriter(&out)
	for _, file := range r.File {
		if file.Name == "xl/calcChain.xml" {
			continue
		}
		if file.Name != "[Content_Types].xml" && file.Name != "xl/_rels/workbook.xml.rels" {
			if err = w.Copy(file); err != nil {
				return nil, err
			}
			continue
		}
		stream, e := file.Open()
		if e != nil {
			return nil, e
		}
		content, e := io.ReadAll(stream)
		stream.Close()
		if e != nil {
			return nil, e
		}
		content, e = removeChainReference(content)
		if e != nil {
			return nil, e
		}
		header := file.FileHeader
		entry, e := w.CreateHeader(&header)
		if e != nil {
			return nil, e
		}
		if _, e = entry.Write(content); e != nil {
			return nil, e
		}
	}
	if err = w.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func removeChainReference(data []byte) ([]byte, error) {
	d := xml.NewDecoder(bytes.NewReader(data))
	var out bytes.Buffer
	keep := int64(0)
	for {
		start := d.InputOffset()
		token, err := d.Token()
		if err == io.EOF {
			out.Write(data[keep:])
			return out.Bytes(), nil
		}
		if err != nil {
			return nil, err
		}
		element, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		remove := false
		for _, attr := range element.Attr {
			if element.Name.Local == "Override" && attr.Name.Local == "PartName" && attr.Value == "/xl/calcChain.xml" || element.Name.Local == "Relationship" && attr.Name.Local == "Type" && attr.Value == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" {
				remove = true
			}
		}
		if remove {
			out.Write(data[keep:start])
			if err = d.Skip(); err != nil {
				return nil, err
			}
			keep = d.InputOffset()
		}
	}
}
