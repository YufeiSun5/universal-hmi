package runtime

import (
	"context"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"testing"
	"time"
)

func TestSelectedValuesRespectQualityConnectionAndTransitiveScope(t *testing.T) {
	e, ps := setup(t)
	p, err := ps.Create(points.CreateInput{Station: "B", Name: "source", SourceType: "mqtt", SourceID: "s", SourcePath: "p", DataType: "FLOAT"})
	if err != nil {
		t.Fatal(err)
	}
	v, err := ps.Create(points.CreateInput{Station: "A", Name: "derived", SourceType: "virtual", DataType: "FLOAT", Expression: "v[0]*2", Inputs: []string{p.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.Apply(); err != nil {
		t.Fatal(err)
	}
	a := authorization.Actor{Valid: func() bool { return true }, StationID: func(n string) string { return n }, Grants: authorization.Grants{Roles: []string{"viewer"}, AllStations: true}}
	ctx := authorization.WithActor(context.Background(), a)
	seed := func(q, state string, ts time.Time) {
		e.mu.Lock()
		defer e.mu.Unlock()
		e.sourceState["s"] = state
		e.live[p.ID] = storage.Sample{PointID: p.ID, Station: "B", Value: 2.0, Raw: 2.0, Quality: q, SourceTime: ts}
		e.live[v.ID] = storage.Sample{PointID: v.ID, Station: "A", Value: 4.0, Quality: "good", SourceTime: ts}
	}
	seed("good", "connected", time.Now())
	rows, err := e.ReadPointsFor(ctx, []string{v.ID, p.ID})
	if err != nil || len(rows) != 2 || rows[v.ID].Quality != "good" || rows[p.ID].Raw != nil {
		t.Fatal(rows, err)
	}
	for _, tt := range []struct {
		q, state string
		ts       time.Time
	}{{"good", "disconnected", time.Now()}, {"bad", "connected", time.Now()}, {"good", "connected", time.Now().Add(-time.Hour)}} {
		seed(tt.q, tt.state, tt.ts)
		rows, err = e.ReadPointsFor(ctx, []string{v.ID, p.ID})
		if err != nil || rows[v.ID].Quality == "good" || rows[p.ID].Quality == "good" {
			t.Fatal(rows, err)
		}
	}
	seed("good", "connected", time.Now())
	a.Grants.AllStations = false
	a.Grants.StationIDs = []string{"A"}
	ctx = authorization.WithActor(context.Background(), a)
	rows, err = e.ReadPointsFor(ctx, []string{v.ID, p.ID})
	if err != nil || len(rows) != 1 || rows[v.ID].Quality != "invalid_dependency" || rows[v.ID].Value != nil {
		t.Fatal("cross-station leak", rows, err)
	}
	if _, err = e.ReadPointsFor(ctx, make([]string, 201)); err == nil {
		t.Fatal("unbounded request")
	}
	e.RequireIdentity()
	if _, err = e.ReadPointsFor(context.Background(), []string{p.ID}); err == nil {
		t.Fatal("missing identity accepted")
	}
}
