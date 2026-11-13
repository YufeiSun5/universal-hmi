package materials

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestOperationChains(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			s := f.s
			requester := testContext("requester", authorization.Grants{MaterialsRequest: true})
			app := must(s.Submit(requester, ApplicationInput{Mutation: operation(), Text: "初次申请"}))(t)
			must(s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 1, Decision: "rejected", Reason: "补充用途"}))(t)
			app = must(s.Submit(requester, ApplicationInput{Mutation: operation(), ID: app.ID, Version: 1, Text: "改为维修用途"}))(t)
			app = must(s.Approve(f.reviewer, app.ID, ApprovalInput{Mutation: operation(), Version: 2, Decision: "approved"}))(t)
			in1 := f.inbound(t, "10", app)
			f.inbound(t, "5", app)
			independent := f.inbound(t, "1", Application{})
			out := must(s.Confirm(f.ctx, "outbound", f.outboundInput(t, "5")))(t)
			ret := must(s.Confirm(f.ctx, "return", DocumentInput{Mutation: operation(), SourceID: out.ID, SignatureVersion: f.sig.Version, Lines: []LineInput{{SourceLineID: out.Lines[0].ID, TargetCategoryID: f.scrap.ID, Quantity: "2"}}}))(t)
			balance := f.stock(t, f.normal.ID)
			transfer := must(s.Confirm(f.ctx, "transfer", DocumentInput{Mutation: operation(), Lines: []LineInput{{ItemID: f.item.ID, CategoryID: f.normal.ID, TargetCategoryID: f.scrap.ID, Quantity: "4", ItemVersion: balance.Version, BalanceVersion: balance.BalanceVersion}}}))(t)
			p := must(s.Chains(f.ctx, Filter{}))(t)
			if p.Total != 4 {
				t.Fatalf("expected four real roots, got %+v", p)
			}
			chain := must(s.Chain(f.ctx, "application", app.ID, Filter{}))(t)
			want := []string{"submit", "rejected", "resubmit", "approved", "inbound", "inbound"}
			if chain.Nodes.Total != len(want) {
				t.Fatalf("nodes %+v", chain)
			}
			for i, kind := range want {
				if chain.Nodes.Items[i].Kind != kind {
					t.Fatalf("node %d: %+v", i, chain.Nodes.Items[i])
				}
			}
			if chain.Nodes.Items[0].Application.Status != "pending" || chain.Nodes.Items[0].Application.Decided != "" || chain.Nodes.Items[2].Application.SignatureID != "" {
				t.Fatal("submission acquired later decision fields")
			}
			if chain.Nodes.Items[1].Application.Text != "初次申请" || chain.Nodes.Items[2].Application.Text != "改为维修用途" || chain.Nodes.Items[3].Application.SignatureID == "" {
				t.Fatal("version/signature lost")
			}
			page := must(s.Chain(f.ctx, "application", app.ID, Filter{Offset: 4, Limit: 1}))(t)
			if page.Nodes.Total != 6 || len(page.Nodes.Items) != 1 || page.Nodes.Items[0].ReferenceID != in1.ID {
				t.Fatal("chain paging changed totals/order")
			}
			outChain := must(s.Chain(f.ctx, "outbound", out.ID, Filter{}))(t)
			if outChain.Nodes.Total != 2 || outChain.Nodes.Items[1].ReferenceID != ret.ID || outChain.Chain.Status != "part_returned" || outChain.Chain.Lines[0].Remaining != "3" {
				t.Fatalf("return chain %+v", outChain)
			}
			for _, d := range []Document{independent, transfer} {
				c := must(s.Chain(f.ctx, d.Kind, d.ID, Filter{}))(t)
				if c.Nodes.Total != 1 {
					t.Fatal("false source relationship")
				}
			}
			if _, e := s.Chain(f.ctx, "inbound", in1.ID, Filter{}); !errors.Is(e, ErrMissing) {
				t.Fatalf("linked inbound duplicated as standalone: %v", e)
			}
			for _, filter := range []Filter{{Kind: "outbound"}, {Search: ret.Number}, {CategoryID: f.scrap.ID, Kind: "outbound"}, {OwnerID: "reviewer"}, {From: in1.Created, To: in1.Created}} {
				p := must(s.Chains(f.ctx, filter))(t)
				if p.Total != 1 {
					t.Fatalf("filter %+v => %+v", filter, p)
				}
			}
			paged := must(s.Chains(f.ctx, Filter{Limit: 1, Offset: 3}))(t)
			if paged.Total != 4 || len(paged.Items) != 1 {
				t.Fatal("root pagination")
			}
			parent := must(s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: Category{Name: "上级"}}))(t)
			f.scrap.ParentID = parent.ID
			must(s.SaveCategory(f.ctx, CategoryInput{Mutation: operation(), Category: f.scrap}))(t)
			p = must(s.Chains(f.ctx, Filter{CategoryID: parent.ID}))(t)
			if p.Total != 2 {
				t.Fatalf("descendant categories %+v", p)
			}
			// Filtering and pagination must take place after authorization; the user
			// may see related inbound quantities but not identities/prices/assets.
			for _, tc := range []struct {
				ctx   context.Context
				count int
			}{{requester, 1}, {testContext("another", authorization.Grants{MaterialsRequest: true}), 0}, {testContext("inbound-only", authorization.Grants{MaterialsInbound: true}), 2}, {testContext("out-only", authorization.Grants{MaterialsOutbound: true}), 1}, {testContext("catalog-only", authorization.Grants{MaterialsCatalog: true}), 1}} {
				p := must(s.Chains(tc.ctx, Filter{}))(t)
				if p.Total != tc.count {
					t.Fatalf("permission total %d != %d", p.Total, tc.count)
				}
			}
			limited := must(s.Chain(requester, "application", app.ID, Filter{}))(t)
			n := limited.Nodes.Items[4]
			if !n.SummaryOnly || n.CanOpen || n.Owner != "" || n.Document.Owner != "" || n.Document.KnownAmount != "" || n.Document.Lines[0].Price != "" {
				t.Fatalf("summary exposed fields %+v", n)
			}
			if limited.Nodes.Items[3].Application.SignatureID == "" {
				t.Fatal("own application approval signature missing")
			}
			// An equal display name is not ownership.
			intruder := authorization.WithActor(context.Background(), authorization.Actor{ID: "stranger", DisplayName: "requester", Grants: authorization.Grants{MaterialsRequest: true, MaterialsInbound: true}, Valid: func() bool { return true }})
			limited = must(s.Chain(intruder, "application", app.ID, Filter{}))(t)
			if limited.Nodes.Total != 4 {
				t.Fatalf("inbound-only exposed rejected version: %+v", limited)
			}
			b, _ := json.Marshal(limited)
			if strings.Contains(string(b), "初次申请") || strings.Contains(string(b), "补充用途") {
				t.Fatal("old version leaked")
			}
			for _, n := range limited.Nodes.Items {
				if n.Application != nil && n.Application.SignatureID != "" {
					t.Fatal("signature leaked via duplicate display name")
				}
			}
			if _, e := s.Chain(requester, "outbound", out.ID, Filter{}); !errors.Is(e, ErrMissing) {
				t.Fatalf("unauthorized root: %v", e)
			}
			if _, e := s.Chains(testContext("none", authorization.Grants{}), Filter{}); !errors.Is(e, authorization.ErrDenied) {
				t.Fatal("ungranted chains allowed")
			}
			if _, e := s.Chains(f.ctx, Filter{Kind: "signature"}); e == nil {
				t.Fatal("unsupported category accepted")
			}
			if _, e := s.Chain(f.ctx, "application", app.ID, Filter{Limit: 201}); e == nil {
				t.Fatal("unbounded page accepted")
			}
		})
	}
}
