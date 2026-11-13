package materials

import (
	"context"
	"errors"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/shopspring/decimal"
)

func (s *Service) Submit(ctx context.Context, in ApplicationInput) (Application, error) {
	return mutate(ctx, s, "request", "application", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Application, error) {
		v := Application{}
		if !textValid(in.Text, 10000, true) {
			return v, invalid("申请正文（最多10000字）")
		}
		if in.ID == "" {
			if in.Version != 0 {
				return v, ErrConflict
			}
			v.ID = id()
			v.Number = number("SQ", v.ID)
			v.OwnerID = a.ID
			v.Owner = a.DisplayName
		} else {
			var e error
			v, e = getApplication(tx, in.ID)
			if e != nil {
				return v, e
			}
			if v.OwnerID != a.ID {
				return Application{}, authorization.ErrDenied
			}
			if v.Version != in.Version || v.Status != "rejected" {
				return Application{}, ErrConflict
			}
		}
		v.ApplicationVersion = ApplicationVersion{Version: v.Version + 1, Text: strings.TrimSpace(in.Text), Submitted: now(), Status: "pending"}
		_, e := tx.Exec("INSERT INTO materials_applications(id,owner_id,version,status,created,search,body) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,status=excluded.status,created=excluded.created,search=excluded.search,body=excluded.body", v.ID, v.OwnerID, v.Version, v.Status, v.Submitted, strings.ToLower(v.Number+" "+v.Owner+" "+v.Text), raw(v))
		if e != nil {
			return v, e
		}
		_, e = tx.Exec("INSERT INTO materials_application_versions(application_id,version,body) VALUES(?,?,?)", v.ID, v.Version, raw(v.ApplicationVersion))
		return v, e
	})
}
func (s *Service) Approve(ctx context.Context, key string, in ApprovalInput) (Application, error) {
	return mutate(ctx, s, "approve", "approve/"+key, in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Application, error) {
		v, e := getApplication(tx, key)
		if e != nil {
			return v, e
		}
		if v.OwnerID == a.ID {
			return Application{}, errors.New("不能审批自己的申请")
		}
		if v.Version != in.Version || v.Status != "pending" {
			return Application{}, ErrConflict
		}
		if in.Decision != "approved" && in.Decision != "rejected" {
			return Application{}, invalid("审批决定")
		}
		if !textValid(in.Reason, 2000, in.Decision == "rejected") {
			return Application{}, invalid("驳回原因")
		}
		if in.Decision == "approved" {
			sig, e := signature(tx, a.ID)
			if e != nil {
				return v, e
			}
			if sig.AssetID == "" {
				return v, ErrSignature
			}
			v.SignatureID = sig.AssetID
		}
		v.Status = in.Decision
		v.Reason = strings.TrimSpace(in.Reason)
		v.ApproverID = a.ID
		v.Approver = a.DisplayName
		v.Decided = now()
		res, e := tx.Exec("UPDATE materials_applications SET status=?,body=? WHERE id=? AND version=? AND status='pending'", v.Status, raw(v), key, in.Version)
		if e != nil {
			return v, e
		}
		n, e := res.RowsAffected()
		if e != nil {
			return v, e
		}
		if n != 1 {
			return v, ErrConflict
		}
		_, e = tx.Exec("UPDATE materials_application_versions SET body=? WHERE application_id=? AND version=?", raw(v.ApplicationVersion), key, v.Version)
		if e == nil && v.SignatureID != "" {
			_, e = tx.Exec("INSERT INTO materials_application_signatures(application_id,version,asset_id) VALUES(?,?,?)", key, v.Version, v.SignatureID)
		}
		return v, e
	})
}
func applicationAccess(a authorization.Actor, v Application) bool {
	return a.Grants.MaterialsApprove || a.Grants.MaterialsRequest && v.OwnerID == a.ID || a.Grants.MaterialsInbound && v.Status == "approved"
}
func (s *Service) Applications(ctx context.Context, f Filter) (Page[Application], error) {
	f, err := pagination(f)
	if err != nil {
		return Page[Application]{}, err
	}
	a, e := actor(ctx, "applications")
	if e != nil {
		return Page[Application]{}, e
	}
	where := "search LIKE ? ESCAPE '!'"
	args := []any{like(f.Search)}
	if !a.Grants.MaterialsApprove {
		where += " AND ((owner_id=? AND ?=1) OR (status='approved' AND ?=1))"
		args = append(args, a.ID, boolInt(a.Grants.MaterialsRequest), boolInt(a.Grants.MaterialsInbound))
	}
	if f.Status != "" {
		where += " AND status=?"
		args = append(args, f.Status)
	}
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
	p, e := paged[Application](s.db, "materials_applications", where, "created DESC,id", args, f)
	for i := range p.Items {
		if !a.Grants.MaterialsApprove && !(a.Grants.MaterialsRequest && p.Items[i].OwnerID == a.ID) {
			p.Items[i].SignatureID = ""
		}
	}
	return p, e
}
func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
func (s *Service) Application(ctx context.Context, key string, f Filter) (ApplicationDetail, error) {
	out := ApplicationDetail{Versions: []ApplicationVersion{}, Totals: []Line{}}
	a, e := actor(ctx, "applications")
	if e != nil {
		return out, e
	}
	v, e := getApplication(s.db, key)
	if e != nil {
		return out, e
	}
	if !applicationAccess(a, v) {
		return out, ErrMissing
	}
	out.Application = v
	if a.Grants.MaterialsApprove || a.Grants.MaterialsRequest && v.OwnerID == a.ID {
		out.Versions, e = readMany[ApplicationVersion](s.db, "SELECT body FROM materials_application_versions WHERE application_id=? ORDER BY version", key)
	} else {
		out.Application.SignatureID = ""
		approved := v.ApplicationVersion
		approved.SignatureID = ""
		out.Versions = []ApplicationVersion{approved}
	}
	if e != nil {
		return out, e
	}
	out.Inbound, e = paged[Document](s.db, "materials_documents", "kind='inbound' AND application_id=?", "created DESC,id", []any{key}, f)
	if e != nil {
		return out, e
	}
	if !a.Grants.MaterialsInbound {
		for i := range out.Inbound.Items {
			out.Inbound.Items[i] = inboundSummary(out.Inbound.Items[i])
		}
	}
	rows, e := s.db.Query("SELECT l.item_id,l.quantity,l.body FROM materials_lines l JOIN materials_documents d ON d.id=l.document_id WHERE d.kind='inbound' AND d.application_id=? ORDER BY d.created,d.id,l.id", key)
	if e != nil {
		return out, e
	}
	defer rows.Close()
	positions := map[string]int{}
	totals := map[string]decimal.Decimal{}
	for rows.Next() {
		var key, body string
		var n int64
		if e = rows.Scan(&key, &n, &body); e != nil {
			return out, e
		}
		var line Line
		if e = decodeBody(body, &line); e != nil {
			return out, e
		}
		position, found := positions[key]
		if !found {
			position = len(out.Totals)
			positions[key] = position
			out.Totals = append(out.Totals, Line{ItemID: key, Name: line.Name, Specification: line.Specification, Unit: line.Unit})
		}
		totals[key] = totals[key].Add(decimal.New(n, -4))
		out.Totals[position].Quantity = totals[key].String()
	}
	return out, rows.Err()
}
func inboundSummary(v Document) Document {
	v.AssetIDs = []string{}
	v.SignatureID = ""
	v.OwnerID = ""
	v.Owner = ""
	v.Recipient = ""
	v.Notes = ""
	v.KnownAmount = ""
	v.MissingPrices = 0
	for i := range v.Lines {
		v.Lines[i].Price = ""
		v.Lines[i].Amount = ""
	}
	return v
}
