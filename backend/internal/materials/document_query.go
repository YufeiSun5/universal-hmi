package materials

import (
	"context"
	"database/sql"
	"sort"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/shopspring/decimal"
)

type UnitQuantity struct {
	Unit     string `json:"unit"`
	Quantity string `json:"quantity"`
}
type ProductTotal struct {
	ItemID        string `json:"item_id"`
	Name          string `json:"name"`
	Specification string `json:"specification"`
	Unit          string `json:"unit"`
	Quantity      string `json:"quantity"`
	KnownAmount   string `json:"known_amount"`
	MissingPrices int    `json:"missing_prices"`
}
type DocumentSummary struct {
	Documents     int            `json:"documents"`
	Products      int            `json:"products"`
	Quantities    []UnitQuantity `json:"quantities"`
	KnownAmount   string         `json:"known_amount"`
	MissingPrices int            `json:"missing_prices"`
	Items         []ProductTotal `json:"items"`
	Offset        int            `json:"offset"`
}

// The line predicate is shared by document membership, amounts and quantities.
// Returns belong to the actual destination, while transfers match either side.
func (s *Service) documentLineFilter(f Filter) (string, []any) {
	where := "1=1"
	args := []any{}
	if f.ItemID != "" {
		where += " AND l.item_id=?"
		args = append(args, f.ItemID)
	}
	if f.CategoryID != "" {
		target := s.chainJSON("l.body", "target_category_id")
		where += " AND (" + categoryWithin("CASE WHEN d.kind='return' THEN "+target+" ELSE l.category_id END") + " OR (d.kind='transfer' AND " + categoryWithin(target) + "))"
		args = append(args, f.CategoryID, f.CategoryID)
	}
	return where, args
}
func (s *Service) documentFilter(kind string, f Filter) (string, []any, error) {
	where := "d.kind=? AND d.search LIKE ? ESCAPE '!'"
	args := []any{kind, like(f.Search)}
	for _, v := range []struct{ clause, value string }{
		{"d.owner_id=?", f.OwnerID}, {"d.created>=?", f.From}, {"d.created<=?", f.To}, {"d.created<?", f.Until},
	} {
		if v.value != "" {
			where += " AND " + v.clause
			args = append(args, v.value)
		}
	}
	if f.ItemID != "" || f.CategoryID != "" {
		line, params := s.documentLineFilter(f)
		where += " AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=d.id AND " + line + ")"
		args = append(args, params...)
	}
	if kind == "outbound" && f.Status != "" {
		switch f.Status {
		case "not_returned":
			where += " AND NOT EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=d.id AND l.returned>0)"
		case "returned":
			where += " AND NOT EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=d.id AND l.returned<l.quantity)"
		case "part_returned":
			where += " AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=d.id AND l.returned>0) AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=d.id AND l.returned<l.quantity)"
		default:
			return "", nil, invalid("退库状态")
		}
	}
	return where, args, nil
}
func (s *Service) Documents(ctx context.Context, kind string, f Filter) (Page[Document], error) {
	p := Page[Document]{Items: []Document{}}
	if kind != "inbound" && kind != "outbound" && kind != "return" && kind != "transfer" {
		return p, invalid("单据类型")
	}
	f, e := pagination(f)
	if e != nil {
		return p, e
	}
	a, e := actor(ctx, kind)
	if e != nil {
		return p, e
	}
	options := &sql.TxOptions{ReadOnly: true}
	if s.db.PostgreSQL {
		options.Isolation = sql.LevelRepeatableRead
	}
	tx, e := s.db.BeginTx(ctx, options)
	if e != nil {
		return p, e
	}
	defer tx.Rollback()
	where, args, e := s.documentFilter(kind, f)
	if e != nil {
		return p, e
	}
	if e = tx.QueryRow("SELECT COUNT(*) FROM materials_documents d WHERE "+where, args...).Scan(&p.Total); e != nil {
		return p, e
	}
	pageArgs := append(append([]any{}, args...), f.Limit, f.Offset)
	p.Items, e = readMany[Document](tx, "SELECT d.body FROM materials_documents d WHERE "+where+" ORDER BY d.created DESC,d.id LIMIT ? OFFSET ?", pageArgs...)
	if e != nil {
		return p, e
	}
	page := map[string]*Document{}
	for i := range p.Items {
		p.Items[i], e = withReturns(tx, p.Items[i])
		if e != nil {
			return p, e
		}
		p.Items[i].MatchedAmount = "0.00"
		page[p.Items[i].ID] = &p.Items[i]
	}
	p.Summary, e = s.documentSummary(tx, kind, f, p.Total, page)
	if e != nil {
		return p, e
	}
	if kind == "outbound" {
		// Occurrence-period returns are intentionally independent of the date or
		// current return status of their source outbound document.
		rf := f
		rf.Status = ""
		rw, ra, err := s.documentFilter("return", rf)
		if err != nil {
			return p, err
		}
		var count int
		if e = tx.QueryRow("SELECT COUNT(*) FROM materials_documents d WHERE "+rw, ra...).Scan(&count); e != nil {
			return p, e
		}
		p.ReturnSummary, e = s.documentSummary(tx, "return", rf, count, nil)
		if e != nil {
			return p, e
		}
	}
	if !a.Active() {
		return Page[Document]{}, authorization.ErrDenied
	}
	return p, nil
}
func (s *Service) documentSummary(q queryer, kind string, f Filter, count int, page map[string]*Document) (*DocumentSummary, error) {
	out := &DocumentSummary{Documents: count, Quantities: []UnitQuantity{}, Items: []ProductTotal{}, KnownAmount: "0.00", Offset: f.SummaryOffset}
	where, args, e := s.documentFilter(kind, f)
	if e != nil {
		return out, e
	}
	line, params := s.documentLineFilter(f)
	args = append(args, params...)
	rows, e := q.Query("SELECT d.id,l.body FROM materials_documents d JOIN materials_lines l ON l.document_id=d.id WHERE "+where+" AND "+line, args...)
	if e != nil {
		return out, e
	}
	defer rows.Close()
	quantities := map[string]decimal.Decimal{}
	products := map[string]*ProductTotal{}
	total := decimal.Zero
	for rows.Next() {
		var key, body string
		var l Line
		if e = rows.Scan(&key, &body); e != nil {
			return out, e
		}
		if e = decodeBody(body, &l); e != nil {
			return out, e
		}
		n, err := decimal.NewFromString(l.Quantity)
		if err != nil {
			return out, err
		}
		quantities[l.Unit] = quantities[l.Unit].Add(n)
		product := products[l.ItemID]
		if product == nil {
			product = &ProductTotal{ItemID: l.ItemID, Name: l.Name, Specification: l.Specification, Unit: l.Unit, Quantity: "0", KnownAmount: "0.00"}
			products[l.ItemID] = product
		}
		previous, err := decimal.NewFromString(product.Quantity)
		if err != nil {
			return out, err
		}
		product.Quantity = previous.Add(n).String()
		doc := page[key]
		if l.Amount == "" {
			out.MissingPrices++
			product.MissingPrices++
			if doc != nil {
				doc.MatchedMissingPrices++
			}
		} else {
			value, err := decimal.NewFromString(l.Amount)
			if err != nil {
				return out, err
			}
			total = total.Add(value)
			previous, err = decimal.NewFromString(product.KnownAmount)
			if err != nil {
				return out, err
			}
			product.KnownAmount = previous.Add(value).StringFixed(2)
			if doc != nil {
				previous, err = decimal.NewFromString(doc.MatchedAmount)
				if err != nil {
					return out, err
				}
				doc.MatchedAmount = previous.Add(value).StringFixed(2)
			}
		}
	}
	if e = rows.Err(); e != nil {
		return out, e
	}
	out.KnownAmount = total.StringFixed(2)
	out.Products = len(products)
	for unit, n := range quantities {
		out.Quantities = append(out.Quantities, UnitQuantity{Unit: unit, Quantity: n.String()})
	}
	sort.Slice(out.Quantities, func(i, j int) bool { return out.Quantities[i].Unit < out.Quantities[j].Unit })
	all := make([]ProductTotal, 0, len(products))
	for _, p := range products {
		all = append(all, *p)
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].Name == all[j].Name {
			return all[i].ItemID < all[j].ItemID
		}
		return all[i].Name < all[j].Name
	})
	if f.SummaryOffset < len(all) {
		end := f.SummaryOffset + 50
		if end > len(all) {
			end = len(all)
		}
		out.Items = all[f.SummaryOffset:end]
	}
	return out, nil
}
