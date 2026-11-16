package materials

import (
	"context"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/shopspring/decimal"
)

// Submit always starts the four-stage workflow, including older clients which
// omit the workflow marker. Existing historical records keep their old meaning.
func (s *Service) Submit(ctx context.Context, in ApplicationInput) (Application, error) {
	if in.Workflow != 0 && in.Workflow != 2 {
		return Application{}, invalid("申请流程版本")
	}
	in.Workflow = 2
	return s.submitRequisition(ctx, in)
}
func (s *Service) Approve(ctx context.Context, key string, in ApprovalInput) (Application, error) {
	if in.Stage != "" {
		return s.decideRequisition(ctx, key, in)
	}
	return mutate(ctx, s, "approve", "approve/"+key, in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Application, error) {
		v, e := getApplication(tx, key)
		if e != nil {
			return v, e
		}
		if v.Workflow == 2 {
			return v, ErrConflict
		}
		if v.OwnerID == a.ID && !a.Grants.MaterialsRequest {
			return Application{}, authorization.ErrDenied
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
	return requisitionAccess(a.Grants) || a.Grants.MaterialsInbound && (v.Status == "approved" || v.Status == "receipt" || v.Status == "closed")
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
	if f.InboundStatus != "" {
		if f.InboundStatus != "none" {
			return Page[Application]{}, invalid("入库筛选条件")
		}
		if !a.Grants.MaterialsInbound {
			return Page[Application]{}, authorization.ErrDenied
		}
		where += " AND NOT EXISTS (SELECT 1 FROM materials_documents d WHERE d.kind='inbound' AND d.application_id=materials_applications.id)"
	}
	if !requisitionAccess(a.Grants) {
		where += " AND status IN ('approved','receipt','closed')"
	}
	if f.Status == "todo" {
		where += " AND ((status='review' AND ?=1) OR (status='approval' AND ?=1) OR (status='receipt' AND ?=1) OR (status='pending' AND ?=1) OR (status='rejected' AND owner_id=? AND ?=1))"
		args = append(args, boolInt(a.Grants.MaterialsReview), boolInt(a.Grants.MaterialsApprove), boolInt(a.Grants.MaterialsReceive), boolInt(a.Grants.MaterialsApprove), a.ID, boolInt(a.Grants.MaterialsRequest))
	} else if f.Status == "approved" {
		where += " AND status IN ('approved','receipt','closed')"
	} else if f.Status != "" {
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
	if f.Until != "" {
		where += " AND created<?"
		args = append(args, f.Until)
	}
	p, e := paged[Application](s.db, "materials_applications", where, "created DESC,id", args, f)
	for i := range p.Items {
		if !requisitionAccess(a.Grants) {
			p.Items[i].SignatureID = ""
			p.Items[i].Steps = nil
			p.Items[i].Requisition.AssetIDs = nil
			p.Items[i].Requisition.Attachments = nil
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
	if requisitionAccess(a.Grants) {
		out.Versions, e = readMany[ApplicationVersion](s.db, "SELECT body FROM materials_application_versions WHERE application_id=? ORDER BY version", key)
	} else {
		out.Application.SignatureID = ""
		out.Application.Steps = nil
		out.Application.Requisition.AssetIDs = nil
		out.Application.Requisition.Attachments = nil
		approved := v.ApplicationVersion
		approved.SignatureID = ""
		approved.Steps = nil
		approved.Requisition.AssetIDs = nil
		approved.Requisition.Attachments = nil
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
