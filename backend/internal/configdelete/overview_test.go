package configdelete

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"testing"
)

func TestOverviewBindingsPreventDeletingReferencedVariable(t *testing.T) {
	s, _ := setup(t)
	p := variable(t, s, "overview reading")
	if err := s.Store.SaveConfig("live_overview_v1", map[string]any{"revision": 1, "rows": []any{map[string]any{"station": "owner", "bindings": map[string]string{"temperature": p.ID}}}}); err != nil {
		t.Fatal(err)
	}
	request := Request{Targets: []Target{{ID: p.ID, Revision: points.Revision(p)}}}
	preview, err := s.Run(context.Background(), request, false, false)
	if err != nil || preview.CanCommit || len(preview.Items) != 1 || len(preview.Items[0].References) != 1 || preview.Items[0].References[0].Kind != "live_overview_v1" {
		t.Fatal(preview, err)
	}
	request.PreviewToken = preview.PreviewToken
	if _, err = s.Run(context.Background(), request, false, true); err == nil {
		t.Fatal("deleted bound variable")
	}
	if len(s.Points.List()) != 1 {
		t.Fatal("variable lost")
	}
}
