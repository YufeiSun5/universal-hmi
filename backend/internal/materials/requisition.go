package materials

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

func requisitionAccess(g authorization.Grants) bool {
	return g.MaterialsRequest || g.MaterialsReview || g.MaterialsApprove || g.MaterialsReceive
}

func validateRequisition(in ApplicationInput) error {
	r := in.Requisition
	if !textValid(in.Text, 10000, false) || (strings.TrimSpace(in.Text) == "" && len(r.Lines) == 0) {
		return invalid("请填写申请说明或物资明细")
	}
	for _, v := range []string{r.Project, r.ProjectNumber, r.RequestedAt, r.Contractor} {
		if !textValid(v, 500, false) {
			return invalid("工程信息")
		}
	}
	if len(r.Lines) > 1000 || len(r.AssetIDs) > 10 {
		return invalid("最多1000条明细、10个附件")
	}
	for _, l := range r.Lines {
		if !textValid(l.Name, 500, true) || !textValid(l.Specification, 500, false) || !textValid(l.Unit, 100, true) || !textValid(l.Notes, 2000, false) {
			return invalid("物资名称、单位或备注")
		}
		if _, e := units(l.Quantity, true); e != nil {
			return e
		}
		if len(l.NeededAt) > 4000 || (len(l.NeededAt) > 0 && !json.Valid(l.NeededAt)) {
			return invalid("需求时间")
		}
	}
	return nil
}

func (s *Service) submitRequisition(ctx context.Context, in ApplicationInput) (Application, error) {
	return mutate(ctx, s, "request", "requisition", in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Application, error) {
		if e := validateRequisition(in); e != nil {
			return Application{}, e
		}
		v := Application{ID: id(), OwnerID: a.ID, Owner: a.DisplayName}
		v.Number = number("SQ", v.ID)
		if in.ID != "" {
			var e error
			v, e = getApplication(tx, in.ID)
			if e != nil {
				return v, e
			}
			if v.OwnerID != a.ID {
				return v, authorization.ErrDenied
			}
			if v.Version != in.Version || v.Status != "rejected" {
				return v, ErrConflict
			}
		} else if in.Version != 0 {
			return v, ErrConflict
		}
		// Only attachments uploaded by this compiler can be linked to the application.
		seen := map[string]bool{}
		in.Requisition.Attachments = nil
		for _, key := range in.Requisition.AssetIDs {
			if seen[key] {
				return v, invalid("重复附件")
			}
			seen[key] = true
			var owner, kind string
			if e := tx.QueryRow("SELECT owner_id,kind FROM materials_assets WHERE id=?", key).Scan(&owner, &kind); e != nil {
				return v, ErrMissing
			}
			if owner != a.ID || kind != "attachment" {
				return v, authorization.ErrDenied
			}
			asset, e := readJSON[Asset](tx, "SELECT body FROM materials_assets WHERE id=?", key)
			if e != nil {
				return v, e
			}
			in.Requisition.Attachments = append(in.Requisition.Attachments, asset)
		}
		step, e := requisitionStep(tx, a, "compile", "submitted", "")
		if e != nil {
			return v, e
		}
		v.ApplicationVersion = ApplicationVersion{Version: v.Version + 1, Workflow: 2, Text: strings.TrimSpace(in.Text), Requisition: in.Requisition, Submitted: step.Created, Status: "review", Steps: []ApplicationStep{step}}
		search := strings.ToLower(v.Number + " " + v.Owner + " " + v.Text + " " + raw(v.Requisition))
		_, e = tx.Exec("INSERT INTO materials_applications(id,owner_id,version,status,created,search,body) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,status=excluded.status,created=excluded.created,search=excluded.search,body=excluded.body", v.ID, v.OwnerID, v.Version, v.Status, v.Submitted, search, raw(v))
		if e != nil {
			return v, e
		}
		_, e = tx.Exec("INSERT INTO materials_application_versions(application_id,version,body) VALUES(?,?,?)", v.ID, v.Version, raw(v.ApplicationVersion))
		if e != nil {
			return v, e
		}
		for _, key := range append(append([]string{}, v.Requisition.AssetIDs...), step.SignatureID) {
			if e = linkRequisitionAsset(tx, v, key); e != nil {
				return v, e
			}
		}
		return v, nil
	})
}

func requisitionStep(tx *persistence.Tx, a authorization.Actor, stage, decision, reason string) (ApplicationStep, error) {
	step := ApplicationStep{ID: id(), Stage: stage, Decision: decision, ActorID: a.ID, Actor: a.DisplayName, Created: now(), Reason: strings.TrimSpace(reason)}
	if decision != "rejected" {
		sig, e := signature(tx, a.ID)
		if e != nil {
			return step, e
		}
		if sig.AssetID == "" {
			return step, ErrSignature
		}
		step.SignatureID = sig.AssetID
	}
	return step, nil
}
func linkRequisitionAsset(tx *persistence.Tx, v Application, key string) error {
	if key == "" {
		return nil
	}
	_, e := tx.Exec("INSERT INTO materials_requisition_assets(application_id,version,asset_id) VALUES(?,?,?) ON CONFLICT(application_id,version,asset_id) DO NOTHING", v.ID, v.Version, key)
	return e
}
func (s *Service) decideRequisition(ctx context.Context, key string, in ApprovalInput) (Application, error) {
	capability := map[string]string{"review": "review", "approval": "approve", "receipt": "receive"}[in.Stage]
	if capability == "" {
		return Application{}, invalid("办理节点")
	}
	return mutate(ctx, s, capability, "requisition/"+key, in.OperationID, in, func(tx *persistence.Tx, a authorization.Actor) (Application, error) {
		v, e := getApplication(tx, key)
		if e != nil {
			return v, e
		}
		if v.Workflow != 2 || v.Version != in.Version || v.Status != in.Stage {
			return v, ErrConflict
		}
		if in.Stage == "receipt" {
			if in.Decision != "received" {
				return v, invalid("物资只能确认已阅")
			}
		} else if in.Decision != "approved" && in.Decision != "rejected" {
			return v, invalid("办理决定")
		}
		if !textValid(in.Reason, 2000, in.Decision == "rejected") {
			return v, invalid("退回原因")
		}
		step, e := requisitionStep(tx, a, in.Stage, in.Decision, in.Reason)
		if e != nil {
			return v, e
		}
		v.Steps = append(v.Steps, step)
		v.Status = map[string]string{"review": "approval", "approval": "receipt", "receipt": "closed"}[in.Stage]
		if in.Decision == "rejected" {
			v.Status = "rejected"
		}
		v.Reason = step.Reason
		if in.Stage == "approval" {
			v.ApproverID = a.ID
			v.Approver = a.DisplayName
			v.Decided = step.Created
			v.SignatureID = step.SignatureID
		}
		result, e := tx.Exec("UPDATE materials_applications SET status=?,body=? WHERE id=? AND version=? AND status=?", v.Status, raw(v), key, in.Version, in.Stage)
		if e != nil {
			return v, e
		}
		n, e := result.RowsAffected()
		if e != nil {
			return v, e
		}
		if n != 1 {
			return v, ErrConflict
		}
		_, e = tx.Exec("UPDATE materials_application_versions SET body=? WHERE application_id=? AND version=?", raw(v.ApplicationVersion), key, v.Version)
		if e != nil {
			return v, e
		}
		return v, linkRequisitionAsset(tx, v, step.SignatureID)
	})
}
