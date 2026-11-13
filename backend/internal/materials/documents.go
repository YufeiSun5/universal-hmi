package materials

import (
	"context"
	"errors"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/shopspring/decimal"
)

func (s *Service) Confirm(ctx context.Context, kind string, in DocumentInput) (Document, error) {
	if kind != "inbound" && kind != "outbound" && kind != "return" && kind != "transfer" {
		return Document{}, invalid("单据类型")
	}
	return mutate(ctx, s, kind, "document/"+kind, in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Document, error) {
		d := Document{ID: id(), Kind: kind, OwnerID: a.ID, Owner: a.DisplayName, Created: now(), Purpose: strings.TrimSpace(in.Purpose), Recipient: strings.TrimSpace(in.Recipient), Notes: strings.TrimSpace(in.Notes), Lines: []Line{}, AssetIDs: []string{}, Status: "confirmed", KnownAmount: "0.00"}
		d.Number = number(map[string]string{"inbound": "RK", "outbound": "CK", "return": "TK", "transfer": "ZL"}[kind], d.ID)
		if len(in.Lines) < 1 || len(in.Lines) > 100 || !textValid(in.Purpose, 1000, kind == "outbound") || !textValid(in.Recipient, 200, false) || !textValid(in.Notes, 2000, false) {
			return d, invalid("明细、用途、领料人或备注")
		}
		if len(in.AssetIDs) > 10 || kind != "inbound" && len(in.AssetIDs) > 0 {
			return d, invalid("凭证图片（仅入库最多10张）")
		}
		if in.ApplicationID != "" {
			if kind != "inbound" {
				return d, invalid("申请关联")
			}
			app, e := getApplication(tx, in.ApplicationID)
			if e != nil {
				return d, e
			}
			if app.Status != "approved" || app.Version != in.ApplicationVersion {
				return d, ErrConflict
			}
			d.ApplicationID = app.ID
			d.ApplicationVersion = app.Version
		}
		var original Document
		if kind == "return" {
			var e error
			original, e = getDocument(tx, in.SourceID)
			if e != nil {
				return d, e
			}
			if original.Kind != "outbound" || original.OwnerID != a.ID {
				return d, authorization.ErrDenied
			}
			d.SourceID = original.ID
		} else if in.SourceID != "" {
			return d, invalid("原出库单")
		}
		if kind == "outbound" || kind == "return" {
			sig, e := confirmedSignature(tx, a.ID, in.SignatureVersion)
			if e != nil {
				return d, e
			}
			d.SignatureID = sig
		}
		seenAssets := map[string]bool{}
		for _, key := range in.AssetIDs {
			if seenAssets[key] {
				return d, invalid("重复凭证")
			}
			seenAssets[key] = true
			var owner, assetKind string
			if e := tx.QueryRow("SELECT owner_id,kind FROM materials_assets WHERE id=?", key).Scan(&owner, &assetKind); e != nil {
				return d, ErrMissing
			}
			if owner != a.ID || assetKind != "receipt" {
				return d, authorization.ErrDenied
			}
			d.AssetIDs = append(d.AssetIDs, key)
		}
		seen := map[string]bool{}
		total := decimal.Zero
		for _, input := range in.Lines {
			n, e := units(input.Quantity, true)
			if e != nil {
				return d, e
			}
			line := Line{ID: id(), Quantity: quantity(n), Returned: "0", Remaining: quantity(n)}
			if kind == "return" {
				found := false
				for _, old := range original.Lines {
					if old.ID == input.SourceLineID {
						line = old
						found = true
						break
					}
				}
				if !found {
					return d, ErrMissing
				}
				if seen[input.SourceLineID] {
					return d, invalid("重复退库明细")
				}
				seen[input.SourceLineID] = true
				line.ID = id()
				line.SourceLineID = input.SourceLineID
				line.Quantity = quantity(n)
				line.Returned = "0"
				line.Remaining = "0"
				line.TargetCategoryID = input.TargetCategoryID
				line.TargetCategory, e = categoryPath(tx, input.TargetCategoryID)
				if e != nil {
					return d, e
				}
				if input.ItemID != "" && input.ItemID != line.ItemID || input.Price != "" {
					return d, invalid("原出库明细")
				}
			} else {
				item, e := getItem(tx, input.ItemID)
				if e != nil {
					return d, e
				}
				line.ItemID = item.ID
				line.Name = item.Name
				line.Specification = item.Specification
				line.Unit = item.Unit
				line.CategoryID = input.CategoryID
				line.Category, e = categoryPath(tx, input.CategoryID)
				if e != nil {
					return d, e
				}
				key := line.ItemID + "/" + line.CategoryID
				if seen[key] {
					return d, errors.New("同一物料及来源分类请合并为一条明细")
				}
				seen[key] = true
				if kind == "outbound" || kind == "transfer" {
					_, version, e := balance(tx, item.ID, line.CategoryID)
					if e != nil {
						return d, e
					}
					if input.ItemVersion != item.Version || input.BalanceVersion != version {
						return d, ErrConflict
					}
					if input.Price != "" {
						return d, errors.New("出库及转类不允许修改单价")
					}
				}
				if kind == "outbound" {
					line.Price = item.Price
				}
				if kind == "inbound" {
					line.Price = input.Price
					if line.Price != "" {
						p, e := units(line.Price, false)
						if e != nil {
							return d, e
						}
						line.Price = quantity(p)
					}
				}
				if kind == "transfer" {
					if input.TargetCategoryID == line.CategoryID {
						return d, errors.New("请选择不同的目标分类")
					}
					line.TargetCategoryID = input.TargetCategoryID
					line.TargetCategory, e = categoryPath(tx, input.TargetCategoryID)
					if e != nil {
						return d, e
					}
				}
			}
			line.Amount, e = amount(n, line.Price)
			if e != nil {
				return d, e
			}
			if line.Amount == "" {
				d.MissingPrices++
			} else {
				value, e := decimal.NewFromString(line.Amount)
				if e != nil {
					return d, e
				}
				total = total.Add(value)
			}
			d.Lines = append(d.Lines, line)
		}
		d.KnownAmount = total.StringFixed(2)
		if kind == "transfer" {
			d.KnownAmount = ""
			d.MissingPrices = 0
		}
		if kind == "outbound" {
			d.Status = "not_returned"
		}
		search := d.Number + " " + d.Owner + " " + d.Purpose + " " + d.Recipient
		for _, l := range d.Lines {
			search += " " + l.Name + " " + l.Specification + " " + l.Category + " " + l.TargetCategory
		}
		if _, e := tx.Exec("INSERT INTO materials_documents(id,kind,owner_id,application_id,source_id,created,search,body) VALUES(?,?,?,?,?,?,?,?)", d.ID, kind, a.ID, d.ApplicationID, d.SourceID, d.Created, strings.ToLower(search), raw(d)); e != nil {
			return d, e
		}
		for _, l := range d.Lines {
			n, e := units(l.Quantity, true)
			if e != nil {
				return d, e
			}
			if _, e = tx.Exec("INSERT INTO materials_lines(document_id,id,item_id,category_id,quantity,returned,body) VALUES(?,?,?,?,?,0,?)", d.ID, l.ID, l.ItemID, l.CategoryID, n, raw(l)); e != nil {
				return d, e
			}
			if kind == "return" {
				res, e := tx.Exec("UPDATE materials_lines SET returned=returned+? WHERE document_id=? AND id=? AND returned+?<=quantity", n, original.ID, l.SourceLineID, n)
				if e != nil {
					return d, e
				}
				changed, e := res.RowsAffected()
				if e != nil {
					return d, e
				}
				if changed != 1 {
					return d, ErrStock
				}
			}
			switch kind {
			case "inbound":
				e = movement(tx, d, l, l.CategoryID, n)
			case "outbound":
				e = movement(tx, d, l, l.CategoryID, -n)
			case "return":
				e = movement(tx, d, l, l.TargetCategoryID, n)
			case "transfer":
				e = movement(tx, d, l, l.CategoryID, -n)
				if e == nil {
					e = movement(tx, d, l, l.TargetCategoryID, n)
				}
			}
			if e != nil {
				return d, e
			}
		}
		for _, key := range d.AssetIDs {
			if _, e := tx.Exec("INSERT INTO materials_document_assets(document_id,asset_id) VALUES(?,?)", d.ID, key); e != nil {
				return d, e
			}
		}
		if d.SignatureID != "" {
			if _, e := tx.Exec("INSERT INTO materials_document_assets(document_id,asset_id) VALUES(?,?)", d.ID, d.SignatureID); e != nil {
				return d, e
			}
		}
		return d, nil
	})
}
func movement(tx *persistence.Tx, d Document, l Line, category string, n int64) error {
	if e := changeBalance(tx, l.ItemID, category, n); e != nil {
		return e
	}
	m := Movement{ID: id(), DocumentID: d.ID, Number: d.Number, Kind: d.Kind, LineID: l.ID, ItemID: l.ItemID, CategoryID: category, Quantity: quantity(n), Actor: d.Owner, Created: d.Created}
	_, e := tx.Exec("INSERT INTO materials_ledger(id,document_id,item_id,category_id,created,body) VALUES(?,?,?,?,?,?)", m.ID, d.ID, l.ItemID, category, d.Created, raw(m))
	return e
}
func withReturns(q queryer, d Document) (Document, error) {
	if d.Kind != "outbound" {
		return d, nil
	}
	rows, e := q.Query("SELECT id,quantity,returned FROM materials_lines WHERE document_id=?", d.ID)
	if e != nil {
		return d, e
	}
	defer rows.Close()
	counts := map[string][2]int64{}
	for rows.Next() {
		var key string
		var n, returned int64
		if e = rows.Scan(&key, &n, &returned); e != nil {
			return d, e
		}
		counts[key] = [2]int64{n, returned}
	}
	if e = rows.Err(); e != nil {
		return d, e
	}
	anyReturned, all := false, true
	for i := range d.Lines {
		v, ok := counts[d.Lines[i].ID]
		if !ok {
			return d, errors.New("单据明细不完整")
		}
		d.Lines[i].Returned = quantity(v[1])
		d.Lines[i].Remaining = quantity(v[0] - v[1])
		anyReturned = anyReturned || v[1] > 0
		all = all && v[0] == v[1]
	}
	d.Status = "not_returned"
	if anyReturned {
		d.Status = "part_returned"
	}
	if all {
		d.Status = "returned"
	}
	return d, nil
}
func (s *Service) Documents(ctx context.Context, kind string, f Filter) (Page[Document], error) {
	f, err := pagination(f)
	if err != nil {
		return Page[Document]{}, err
	}
	if _, e := actor(ctx, kind); e != nil {
		return Page[Document]{}, e
	}
	where := "kind=? AND search LIKE ? ESCAPE '!'"
	args := []any{kind, like(f.Search)}
	if f.OwnerID != "" {
		where += " AND owner_id=?"
		args = append(args, f.OwnerID)
	}
	if f.From != "" {
		where += " AND created>=?"
		args = append(args, f.From)
	}
	if f.To != "" {
		where += " AND created<=?"
		args = append(args, f.To)
	}
	if f.ItemID != "" {
		where += " AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=materials_documents.id AND l.item_id=?)"
		args = append(args, f.ItemID)
	}
	if f.Status != "" && kind == "outbound" {
		switch f.Status {
		case "not_returned":
			where += " AND NOT EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=materials_documents.id AND l.returned>0)"
		case "returned":
			where += " AND NOT EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=materials_documents.id AND l.returned<l.quantity)"
		case "part_returned":
			where += " AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=materials_documents.id AND l.returned>0) AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=materials_documents.id AND l.returned<l.quantity)"
		default:
			return Page[Document]{}, invalid("退库状态")
		}
	}
	p, e := paged[Document](s.db, "materials_documents", where, "created DESC,id", args, f)
	if e != nil {
		return p, e
	}
	for i := range p.Items {
		p.Items[i], e = withReturns(s.db, p.Items[i])
		if e != nil {
			return p, e
		}
	}
	return p, nil
}
func (s *Service) Document(ctx context.Context, key string, f Filter) (DocumentDetail, error) {
	out := DocumentDetail{Returns: Page[Document]{Items: []Document{}}, Movements: Page[Movement]{Items: []Movement{}}}
	a, e := actor(ctx, "personal")
	if e != nil {
		return out, e
	}
	d, e := getDocument(s.db, key)
	if e != nil {
		return out, e
	}
	if !may(a.Grants, d.Kind) {
		return out, ErrMissing
	}
	out.Document, e = withReturns(s.db, d)
	if e != nil {
		return out, e
	}
	out.Movements, e = paged[Movement](s.db, "materials_ledger", "document_id=?", "created,id", []any{key}, f)
	if e != nil {
		return out, e
	}
	if d.Kind == "outbound" {
		out.Returns, e = paged[Document](s.db, "materials_documents", "kind='return' AND source_id=?", "created,id", []any{key}, f)
	}
	if d.ApplicationID != "" {
		app, err := getApplication(s.db, d.ApplicationID)
		if err != nil {
			return out, err
		}
		out.CanReadApplication = applicationAccess(a, app)
	}
	return out, e
}
func (s *Service) Movements(ctx context.Context, f Filter) (Page[Movement], error) {
	f, err := pagination(f)
	if err != nil {
		return Page[Movement]{}, err
	}
	a, e := actor(ctx, "stock")
	if e != nil {
		return Page[Movement]{}, e
	}
	// Balance access does not grant the identity or details of every source
	// document. Apply document-kind permissions before pagination and counting.
	where := "EXISTS(SELECT 1 FROM materials_documents d WHERE d.id=materials_ledger.document_id AND ((d.kind='inbound' AND ?=1) OR (d.kind IN ('outbound','return') AND ?=1) OR (d.kind='transfer' AND ?=1)))"
	args := []any{boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsOutbound), boolInt(a.Grants.MaterialsCatalog)}
	if f.ItemID != "" {
		where += " AND item_id=?"
		args = append(args, f.ItemID)
	}
	if f.CategoryID != "" {
		where += " AND category_id=?"
		args = append(args, f.CategoryID)
	}
	if f.From != "" {
		where += " AND created>=?"
		args = append(args, f.From)
	}
	if f.To != "" {
		where += " AND created<=?"
		args = append(args, f.To)
	}
	return paged[Movement](s.db, "materials_ledger", where, "created DESC,id", args, f)
}
