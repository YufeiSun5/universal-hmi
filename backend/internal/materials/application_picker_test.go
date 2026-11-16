package materials

import (
	"errors"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

func TestApplicationPickerDatesOrderAndUnreceived(t *testing.T) {
	for _, pg := range []bool{false, true} {
		name := "sqlite"
		if pg {
			name = "postgres"
		}
		t.Run(name, func(t *testing.T) {
			f := setup(t, pg)
			create := func(text, submitted string, approved bool) Application {
				v := must(f.s.seedLegacyApplication(f.ctx, ApplicationInput{Mutation: operation(), Text: text}))(t)
				if approved {
					v = must(f.s.Approve(f.reviewer, v.ID, ApprovalInput{Mutation: operation(), Version: v.Version, Decision: "approved"}))(t)
				}
				v.Submitted = submitted
				if _, e := f.s.db.Exec("UPDATE materials_applications SET created=?,body=? WHERE id=?", submitted, raw(v), v.ID); e != nil {
					t.Fatal(e)
				}
				return v
			}
			create("older", "2026-11-08T15:59:59.999999999Z", true)
			first := create("first", "2026-11-08T16:00:00.000000000Z", true)
			received := create("received", "2026-11-10T12:00:00.000000000Z", true)
			last := create("last", "2026-11-15T15:59:59.999999999Z", true)
			create("next day", "2026-11-15T16:00:00.000000000Z", true)
			create("pending", "2026-11-14T12:00:00.000000000Z", false)
			f.inbound(t, "1", received)
			f.inbound(t, "1", Application{}) // Independent receipt cannot mark another request received.
			filter := Filter{Status: "approved", From: "2026-11-08T16:00:00Z", Until: "2026-11-15T16:00:00Z", InboundStatus: "none", Limit: 1}
			page := must(f.s.Applications(f.ctx, filter))(t)
			if page.Total != 2 || len(page.Items) != 1 || page.Items[0].ID != last.ID {
				t.Fatalf("first page: %+v", page)
			}
			filter.Offset = 1
			page = must(f.s.Applications(f.ctx, filter))(t)
			if page.Total != 2 || len(page.Items) != 1 || page.Items[0].ID != first.ID {
				t.Fatalf("second page: %+v", page)
			}
			f.inbound(t, "1", last) // Any partial receipt excludes the request from unreceived.
			filter.Offset = 0
			page = must(f.s.Applications(f.ctx, filter))(t)
			if page.Total != 1 || page.Items[0].ID != first.ID {
				t.Fatalf("after receipt: %+v", page)
			}
			filter.InboundStatus = ""
			page = must(f.s.Applications(f.ctx, filter))(t)
			if page.Total != 3 || page.Items[0].ID != last.ID {
				t.Fatalf("all receipts: %+v", page)
			}
			filter.InboundStatus = "none"
			requester := testContext("warehouse", authorization.Grants{MaterialsRequest: true})
			if _, e := f.s.Applications(requester, filter); !errors.Is(e, authorization.ErrDenied) {
				t.Fatalf("receipt filter permission: %v", e)
			}
			filter.InboundStatus = "invalid"
			if _, e := f.s.Applications(f.ctx, filter); e == nil {
				t.Fatal("invalid receipt filter accepted")
			}
		})
	}
}
