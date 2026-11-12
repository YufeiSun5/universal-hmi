package totalreports

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"github.com/xuri/excelize/v2"
)

func testTemplate() Template {
	return Template{Kind: "electricity", Name: "电报表", Columns: 5, HeaderRows: 2, Cells: []TemplateCell{{R: 0, C: 3, V: 2, Editable: true}, {R: 1, C: 3, V: "表底"}, {R: 1, C: 4, F: "=SUM(E{first}:E{last})"}}, Daily: []TemplateCell{{R: 3, C: 3, Editable: true}, {R: 3, C: 4, F: `=IF(OR(D4="",D3=""),"",(D4-D3)*D$1)`}}, InputColumns: []int{3}}
}
func fixture(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db, e := storage.Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	s, e := Open(db.DB)
	if e != nil {
		t.Fatal(e)
	}
	s.now = func() time.Time { return time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC) }
	ctx := context.Background()
	if e = s.SaveTemplate(ctx, testTemplate()); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Document(ctx, "electricity", 2026); e != nil {
		t.Fatal(e)
	}
	return s, ctx
}
func actor(edit, rollback, all bool) context.Context {
	return authorization.WithActor(context.Background(), authorization.Actor{ID: "editor", ReadOnly: true, Grants: authorization.Grants{Roles: []string{"operator"}, AllStations: all, TotalReportsEdit: edit, TotalReportsRollback: rollback}, Valid: func() bool { return true }})
}
func save(t *testing.T, s *Service, ctx context.Context, id, address, value string, rev int64) Saved {
	t.Helper()
	if _, e := s.Acquire(ctx, "electricity", 2026, LeaseRequest{Client: "test-client", Addresses: []string{address}}); e != nil {
		t.Fatal(e)
	}
	v, e := s.Patch(ctx, "electricity", 2026, Patch{ID: id, Changes: []Change{{address, value, rev, nil}}, Client: "test-client"})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Acquire(ctx, "electricity", 2026, LeaseRequest{Client: "test-client"}); e != nil {
		t.Fatal(e)
	}
	return v
}
func TestCollaborativeMergeConflictAndRetry(t *testing.T) {
	s, _ := fixture(t)
	ctx := actor(true, false, true)
	a := save(t, s, ctx, "operation-1", "D3", "100", 0)
	b := save(t, s, ctx, "operation-2", "D4", "110", 0)
	if a.Revision != 1 || b.Revision != 2 {
		t.Fatal(a, b)
	}
	retry := save(t, s, ctx, "operation-1", "D3", "100", 0)
	if retry.Revision != 1 {
		t.Fatal("retry created another write")
	}
	if _, e := s.Acquire(ctx, "electricity", 2026, LeaseRequest{Client: "test-client", Addresses: []string{"D3", "D5"}}); e != nil {
		t.Fatal(e)
	}
	_, e := s.Patch(ctx, "electricity", 2026, Patch{ID: "operation-3", Changes: []Change{{"D3", "99", 0, nil}, {"D5", "120", 0, nil}}, Client: "test-client"})
	if !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	changes, e := s.Changes(ctx, "electricity", 2026, 1)
	if e != nil || len(changes.Cells) != 1 || changes.Cells[0].Address != "D4" {
		t.Fatal(changes, e)
	}
	_, e = s.Patch(ctx, "electricity", 2026, Patch{ID: "operation-1", Changes: []Change{{"D3", "200", 1, nil}}, Client: "test-client"})
	if e == nil {
		t.Fatal("operation id reused with different body")
	}
}
func TestCheckpointBatchingRollbackAndIndependentGrants(t *testing.T) {
	s, _ := fixture(t)
	edit := actor(true, false, true)
	rollback := actor(false, true, true)
	var rev int64
	for i := 0; i < 100; i++ {
		v := save(t, s, edit, fmt.Sprintf("operation-%d", i), "D4", fmt.Sprint(i+1), rev)
		rev = v.Revision
	}
	cps, e := s.Checkpoints(edit, "electricity", 2026, 0)
	if e != nil || len(cps) != 1 {
		t.Fatal("each edit must not create a checkpoint", len(cps), e)
	}
	before, e := s.CreateCheckpoint(edit, "electricity", 2026, rev)
	if e != nil {
		t.Fatal(e)
	}
	v := save(t, s, edit, "operation-new", "D4", "200", rev)
	in := Rollback{ID: "rollback-1", Checkpoint: before.ID, Expected: v.Revision}
	if _, e = s.Rollback(edit, "electricity", 2026, in); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("edit grant rolled back", e)
	}
	if _, e = s.Patch(rollback, "electricity", 2026, Patch{ID: "operation-denied", Changes: []Change{{"D4", "201", v.Revision, nil}}, Client: "test-client"}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("rollback grant edited", e)
	}
	stale := in
	stale.Expected--
	if _, e = s.Rollback(rollback, "electricity", 2026, stale); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	restored, e := s.Rollback(rollback, "electricity", 2026, in)
	if e != nil || len(restored.Cells) != 1 || restored.Cells[0].Value != "100" {
		t.Fatal(restored, e)
	}
	replay, e := s.Rollback(rollback, "electricity", 2026, in)
	if e != nil || replay.Revision != restored.Revision {
		t.Fatal(replay, e)
	}
	if _, e = s.Document(actor(true, true, false), "electricity", 2026); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal("partial scope leaked aggregate", e)
	}
}
func TestAutoCheckpointIdleAndParameterRollback(t *testing.T) {
	s, ctx := fixture(t)
	save(t, s, ctx, "parameter-1", "D1", "3", 0)
	old := s.now()
	s.now = func() time.Time { return old.Add(11 * time.Minute) }
	if e := s.CheckpointDirty(ctx); e != nil {
		t.Fatal(e)
	}
	if e := s.CheckpointDirty(ctx); e != nil {
		t.Fatal(e)
	}
	cp, e := s.Checkpoints(ctx, "electricity", 2026, 0)
	if e != nil || len(cp) != 2 {
		t.Fatal(cp, e)
	}
	result, e := s.Rollback(ctx, "electricity", 2026, Rollback{ID: "rollback-param", Checkpoint: cp[1].ID, Expected: 1})
	if e != nil || len(result.Cells) != 1 || result.Cells[0].Value != "2" {
		t.Fatal("default parameter not restored", result, e)
	}
}
func TestConcurrentSameCellHasOneWinner(t *testing.T) {
	s, ctx := fixture(t)
	if _, e := s.Acquire(ctx, "electricity", 2026, LeaseRequest{Client: "test-client", Addresses: []string{"D4"}}); e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, e := s.Patch(ctx, "electricity", 2026, Patch{ID: fmt.Sprintf("concurrent-%d", i), Changes: []Change{{"D4", fmt.Sprint(i + 1), 0, nil}}, Client: "test-client"})
			results <- e
		}(i)
	}
	wg.Wait()
	close(results)
	ok, conflict := 0, 0
	for e := range results {
		if e == nil {
			ok++
		} else if errors.Is(e, ErrConflict) {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if ok != 1 || conflict != 1 {
		t.Fatal(ok, conflict)
	}
}
func TestSeasonLeapYearExportAndProtectedCells(t *testing.T) {
	s, ctx := fixture(t)
	d, e := s.Document(ctx, "electricity", 2027)
	if e != nil {
		t.Fatal(e)
	}
	cells := expand(d.Template, d.Year)
	days := map[string]bool{}
	for _, c := range cells {
		if c.C == 0 && c.R >= d.Template.HeaderRows {
			days[fmt.Sprint(c.R)] = true
		}
	}
	if len(days) != 154 {
		t.Fatalf("baseline plus leap season days = %d", len(days))
	}
	for _, value := range []string{`=WEBSERVICE("http://bad")`, "='Other'!A1"} {
		if validContent(value) {
			t.Fatal("unsafe formula allowed", value)
		}
	}
	save(t, s, ctx, "export-base", "D3", "100", 0)
	save(t, s, ctx, "export-day1", "D4", "110", 0)
	data, e := s.Export(ctx, "electricity", 2026)
	if e != nil {
		t.Fatal(e)
	}
	f, e := excelize.OpenReader(bytes.NewReader(data))
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	if len(f.GetSheetList()) != 1 {
		t.Fatal(f.GetSheetList())
	}
	formula, _ := f.GetCellFormula("总体报表", "E4")
	if formula == "" {
		t.Fatal("formula lost")
	}
	v, e := f.CalcCellValue("总体报表", "E4")
	if e != nil || v != "20" {
		t.Fatal(v, e)
	}
	// Updating the catalog cannot rewrite an existing annual document.
	template := testTemplate()
	template.Name = "changed"
	if e = s.SaveTemplate(ctx, template); e != nil {
		t.Fatal(e)
	}
	again, e := s.Document(ctx, "electricity", 2026)
	if e != nil || again.Template.Name == "changed" {
		t.Fatal(again, e)
	}
}
