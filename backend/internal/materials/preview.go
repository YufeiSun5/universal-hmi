package materials

import (
	"context"
	"database/sql"
	"errors"

	"github.com/shopspring/decimal"
)

type OutboundPreview struct {
	Lines         []Line      `json:"lines"`
	Inputs        []LineInput `json:"inputs"`
	Signature     Signature   `json:"signature"`
	KnownAmount   string      `json:"known_amount"`
	MissingPrices int         `json:"missing_prices"`
}

// The UI requests an authoritative decimal preview; returned item/balance and
// signature versions must be echoed at confirmation. Preview never reserves or
// changes inventory, nor creates an idempotent operation or document.
func (s *Service) PreviewOutbound(ctx context.Context, in DocumentInput) (OutboundPreview, error) {
	p := OutboundPreview{Lines: []Line{}, Inputs: []LineInput{}}
	a, e := actor(ctx, "outbound")
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
	if len(in.Lines) < 1 || len(in.Lines) > 100 {
		return p, invalid("明细数量")
	}
	p.Signature, e = signature(tx, a.ID)
	if e != nil {
		return p, e
	}
	if p.Signature.AssetID == "" {
		return p, ErrSignature
	}
	total := decimal.Zero
	seen := map[string]bool{}
	for _, input := range in.Lines {
		n, e := units(input.Quantity, true)
		if e != nil {
			return p, e
		}
		item, e := getItem(tx, input.ItemID)
		if e != nil {
			return p, e
		}
		category, e := categoryPath(tx, input.CategoryID)
		if e != nil {
			return p, e
		}
		stock, version, e := balance(tx, item.ID, input.CategoryID)
		if e != nil {
			return p, e
		}
		if stock < n {
			return p, ErrStock
		}
		key := item.ID + "/" + input.CategoryID
		if seen[key] {
			return p, errors.New("同一物料及来源分类请合并为一条明细")
		}
		seen[key] = true
		value, e := amount(n, item.Price)
		if e != nil {
			return p, e
		}
		if value == "" {
			p.MissingPrices++
		} else {
			d, e := decimal.NewFromString(value)
			if e != nil {
				return p, e
			}
			total = total.Add(d)
		}
		p.Lines = append(p.Lines, Line{ItemID: item.ID, CategoryID: input.CategoryID, Category: category, Name: item.Name, Specification: item.Specification, Unit: item.Unit, Quantity: quantity(n), Price: item.Price, Amount: value})
		p.Inputs = append(p.Inputs, LineInput{ItemID: item.ID, CategoryID: input.CategoryID, Quantity: quantity(n), ItemVersion: item.Version, BalanceVersion: version})
	}
	p.KnownAmount = total.StringFixed(2)
	return p, tx.Commit()
}
