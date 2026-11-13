package materials

import (
	"context"
	"database/sql"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

// Chains project existing immutable business records. They do not infer a
// purchase/stock-batch relationship, nor create a second mutable event ledger.
type ChainSummary struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Number    string `json:"number"`
	Owner     string `json:"owner"`
	Title     string `json:"title"`
	Status    string `json:"status"`
	Started   string `json:"started"`
	Updated   string `json:"updated"`
	NodeCount int    `json:"node_count"`
	Lines     []Line `json:"lines,omitempty"`
}
type ChainNode struct {
	ID            string              `json:"id"`
	Kind          string              `json:"kind"`
	Number        string              `json:"number"`
	Created       string              `json:"created"`
	Owner         string              `json:"owner"`
	ReferenceKind string              `json:"reference_kind"`
	ReferenceID   string              `json:"reference_id"`
	CanOpen       bool                `json:"can_open"`
	SummaryOnly   bool                `json:"summary_only"`
	Application   *ApplicationVersion `json:"application,omitempty"`
	Document      *Document           `json:"document,omitempty"`
}
type ChainDetail struct {
	Chain ChainSummary    `json:"chain"`
	Nodes Page[ChainNode] `json:"nodes"`
}

func (s *Service) chainRead(ctx context.Context) (*persistence.Tx, authorization.Actor, error) {
	a, e := actor(ctx, "chains")
	if e != nil {
		return nil, a, e
	}
	options := &sql.TxOptions{ReadOnly: true}
	if s.db.PostgreSQL {
		options.Isolation = sql.LevelRepeatableRead
	}
	tx, e := s.db.BeginTx(ctx, options)
	return tx, a, e
}

// All field names below are owned constants, never SQL supplied by a caller.
func (s *Service) chainJSON(column, field string) string {
	if s.db.PostgreSQL {
		return "COALESCE((" + column + "::jsonb->>'" + field + "'),'')"
	}
	return "COALESCE(json_extract(" + column + ", '$." + field + "'),'')"
}

func (s *Service) chainCTE(a authorization.Actor) (string, []any) {
	j := s.chainJSON
	fullApp := "(?=1 OR (?=1 AND a.owner_id=?))"
	appAccess := "(" + fullApp + " OR (?=1 AND a.status='approved'))"
	// Inbound-only users get the approved version, as on the original detail.
	versions := "(" + fullApp + " OR (v.version=a.version AND a.status='approved'))"
	args := []any{boolInt(a.Grants.MaterialsApprove), boolInt(a.Grants.MaterialsRequest), a.ID, boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsApprove), boolInt(a.Grants.MaterialsRequest), a.ID}
	base := `WITH app_versions AS (
 SELECT a.id AS root_id, a.owner_id, ` + j("a.body", "owner") + ` AS owner, ` + j("a.body", "number") + ` AS number, v.version, v.body
 FROM materials_applications a JOIN materials_application_versions v ON v.application_id=a.id
 WHERE ` + appAccess + ` AND ` + versions + `
), nodes AS (
 SELECT 'application' AS root_kind, root_id, root_id || ':submit:' || CAST(version AS TEXT) AS node_id,
 CASE WHEN version=1 THEN 'submit' ELSE 'resubmit' END AS event_kind,
 ` + j("body", "submitted") + ` AS created, owner_id AS actor_id, owner AS actor_name, number,
 'application' AS reference_kind, root_id AS reference_id, body,
 number || ' ' || owner || ' ' || ` + j("body", "text") + ` AS search_text
 FROM app_versions
 UNION ALL
 SELECT 'application',root_id,root_id || ':decision:' || CAST(version AS TEXT),
 ` + j("body", "status") + `,` + j("body", "decided") + `,` + j("body", "approver_id") + `,` + j("body", "approver") + `,number,
 'application',root_id,body,number || ' ' || ` + j("body", "approver") + ` || ' ' || ` + j("body", "reason") + `
 FROM app_versions WHERE ` + j("body", "decided") + `<>''
 UNION ALL
 SELECT CASE WHEN d.kind='return' THEN 'outbound' WHEN d.kind='inbound' AND d.application_id<>'' THEN 'application' ELSE d.kind END,
 CASE WHEN d.kind='return' THEN d.source_id WHEN d.kind='inbound' AND d.application_id<>'' THEN d.application_id ELSE d.id END,
 d.id,d.kind,d.created,
 CASE WHEN d.kind='inbound' AND ?=0 THEN '' ELSE d.owner_id END,
 CASE WHEN d.kind='inbound' AND ?=0 THEN '' ELSE ` + j("d.body", "owner") + ` END,
 ` + j("d.body", "number") + `,'document',d.id,d.body,
 CASE WHEN d.kind='inbound' AND ?=0 THEN ` + j("d.body", "number") + ` ELSE d.search END
 FROM materials_documents d
 WHERE (d.kind='inbound' AND (?=1 OR EXISTS(SELECT 1 FROM materials_applications a WHERE a.id=d.application_id AND ` + fullApp + `)))
 OR (d.kind IN ('outbound','return') AND ?=1) OR (d.kind='transfer' AND ?=1)
) `
	args = append(args, boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsInbound), boolInt(a.Grants.MaterialsApprove), boolInt(a.Grants.MaterialsRequest), a.ID, boolInt(a.Grants.MaterialsOutbound), boolInt(a.Grants.MaterialsCatalog))
	return base, args
}

func chainKind(kind string) bool {
	return kind == "application" || kind == "outbound" || kind == "inbound" || kind == "transfer"
}

func (s *Service) Chains(ctx context.Context, f Filter) (Page[ChainSummary], error) {
	out := Page[ChainSummary]{Items: []ChainSummary{}}
	f, e := pagination(f)
	if e != nil {
		return out, e
	}
	if f.Kind != "" && !chainKind(f.Kind) {
		return out, invalid("链路类别")
	}
	tx, a, e := s.chainRead(ctx)
	if e != nil {
		return out, e
	}
	defer tx.Rollback()
	cte, args := s.chainCTE(a)
	where := "1=1"
	add := func(clause string, value any) { where += " AND " + clause; args = append(args, value) }
	if f.Kind != "" {
		add("n.root_kind=?", f.Kind)
	}
	if f.Search != "" {
		add("LOWER(n.search_text) LIKE ? ESCAPE '!'", like(f.Search))
	}
	if f.OwnerID != "" {
		add("n.actor_id=?", f.OwnerID)
	}
	if f.From != "" {
		add("n.created>=?", f.From)
	}
	if f.To != "" {
		add("n.created<=?", f.To)
	}
	if f.ItemID != "" {
		add("n.reference_kind='document' AND EXISTS(SELECT 1 FROM materials_lines l WHERE l.document_id=n.reference_id AND l.item_id=?)", f.ItemID)
	}
	if f.CategoryID != "" {
		// Includes source and destination of transfers. Descendant categories are
		// resolved by stable IDs, including after an ancestor is renamed/moved.
		add(`n.reference_kind='document' AND EXISTS(SELECT 1 FROM materials_ledger l WHERE l.document_id=n.reference_id AND l.category_id IN (
 WITH RECURSIVE subtree(id) AS (SELECT id FROM materials_categories WHERE id=? UNION ALL SELECT c.id FROM materials_categories c JOIN subtree p ON c.parent_id=p.id) SELECT id FROM subtree))`, f.CategoryID)
	}
	cte += `, matched AS (SELECT DISTINCT n.root_kind,n.root_id FROM nodes n WHERE ` + where + `), roots AS (
 SELECT n.root_kind,n.root_id,MIN(n.created) AS started,MAX(n.created) AS updated,COUNT(*) AS node_count
 FROM nodes n JOIN matched m ON n.root_kind=m.root_kind AND n.root_id=m.root_id GROUP BY n.root_kind,n.root_id) `
	if e = tx.QueryRow(cte+"SELECT COUNT(*) FROM roots", args...).Scan(&out.Total); e != nil {
		return out, e
	}
	pageArgs := append(append([]any{}, args...), f.Limit, f.Offset)
	rows, e := tx.Query(cte+"SELECT root_kind,root_id,started,updated,node_count FROM roots ORDER BY updated DESC,root_kind,root_id LIMIT ? OFFSET ?", pageArgs...)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		v := ChainSummary{}
		if e = rows.Scan(&v.Kind, &v.ID, &v.Started, &v.Updated, &v.NodeCount); e != nil {
			break
		}
		out.Items = append(out.Items, v)
	}
	if e == nil {
		e = rows.Err()
	}
	rows.Close()
	if e != nil {
		return out, e
	}
	for i := range out.Items {
		if e = hydrateChain(tx, &out.Items[i], false); e != nil {
			return out, e
		}
	}
	if !a.Active() {
		return Page[ChainSummary]{}, authorization.ErrDenied
	}
	return out, nil
}

func hydrateChain(q queryer, v *ChainSummary, detail bool) error {
	if v.Kind == "application" {
		app, e := getApplication(q, v.ID)
		if e != nil {
			return e
		}
		v.Number, v.Owner, v.Title, v.Status = app.Number, app.Owner, app.Text, app.Status
	} else {
		d, e := getDocument(q, v.ID)
		if e != nil {
			return e
		}
		d, e = withReturns(q, d)
		if e != nil {
			return e
		}
		v.Number, v.Owner, v.Title, v.Status = d.Number, d.Owner, d.Purpose, d.Status
		if detail && d.Kind == "outbound" {
			v.Lines = d.Lines
		}
	}
	if r := []rune(v.Title); len(r) > 120 {
		v.Title = string(r[:120]) + "…"
	}
	return nil
}

func (s *Service) Chain(ctx context.Context, kind, key string, f Filter) (ChainDetail, error) {
	out := ChainDetail{Chain: ChainSummary{ID: key, Kind: kind}, Nodes: Page[ChainNode]{Items: []ChainNode{}}}
	f, e := pagination(f)
	if e != nil {
		return out, e
	}
	if !chainKind(kind) {
		return out, ErrMissing
	}
	tx, a, e := s.chainRead(ctx)
	if e != nil {
		return out, e
	}
	defer tx.Rollback()
	cte, args := s.chainCTE(a)
	args = append(args, kind, key)
	where := " FROM nodes WHERE root_kind=? AND root_id=?"
	var start, end sql.NullString
	if e = tx.QueryRow(cte+"SELECT COUNT(*),MIN(created),MAX(created)"+where, args...).Scan(&out.Nodes.Total, &start, &end); e != nil {
		return out, e
	}
	if out.Nodes.Total == 0 {
		return out, ErrMissing
	}
	out.Chain.NodeCount, out.Chain.Started, out.Chain.Updated = out.Nodes.Total, start.String, end.String
	if e = hydrateChain(tx, &out.Chain, true); e != nil {
		return out, e
	}
	args = append(args, f.Limit, f.Offset)
	rows, e := tx.Query(cte+"SELECT node_id,event_kind,created,actor_name,number,reference_kind,reference_id,body"+where+" ORDER BY created,CASE WHEN event_kind IN ('submit','resubmit') THEN 0 WHEN event_kind IN ('approved','rejected') THEN 1 ELSE 2 END,node_id LIMIT ? OFFSET ?", args...)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		v := ChainNode{CanOpen: true}
		var body string
		if e = rows.Scan(&v.ID, &v.Kind, &v.Created, &v.Owner, &v.Number, &v.ReferenceKind, &v.ReferenceID, &body); e != nil {
			break
		}
		if v.ReferenceKind == "application" {
			app := ApplicationVersion{}
			if e = decodeBody(body, &app); e != nil {
				break
			}
			if v.Kind == "submit" || v.Kind == "resubmit" {
				app.Status = "pending"
				app.Reason = ""
				app.ApproverID = ""
				app.Approver = ""
				app.Decided = ""
				app.SignatureID = ""
			}
			v.Application = &app
		} else {
			d := Document{}
			if e = decodeBody(body, &d); e != nil {
				break
			}
			if d.Kind == "inbound" && !a.Grants.MaterialsInbound {
				d = inboundSummary(d)
				v.CanOpen = false
				v.SummaryOnly = true
			}
			v.Document = &d
		}
		out.Nodes.Items = append(out.Nodes.Items, v)
	}
	if e == nil {
		e = rows.Err()
	}
	rows.Close()
	if e != nil {
		return out, e
	}
	// Recheck owner by stable ID, including duplicate display names.
	if kind == "application" {
		app, err := getApplication(tx, key)
		if err != nil {
			return out, err
		}
		full := a.Grants.MaterialsApprove || a.Grants.MaterialsRequest && app.OwnerID == a.ID
		for i := range out.Nodes.Items {
			v := &out.Nodes.Items[i]
			if v.Application != nil && !full {
				v.Application.SignatureID = ""
			}
		}
	}
	if !a.Active() {
		return ChainDetail{}, authorization.ErrDenied
	}
	return out, nil
}
