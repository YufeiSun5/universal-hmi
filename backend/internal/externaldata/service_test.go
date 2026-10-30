package externaldata

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func fixture(t *testing.T) (*Service, Source, Screen) {
	t.Helper()
	dir := t.TempDir()
	repo, e := storage.Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { repo.Close() })
	s, e := Open(repo, filepath.Join(dir, "secrets"))
	if e != nil {
		t.Fatal(e)
	}
	pw := "synthetic-only-test"
	v, e := s.SaveSource(context.Background(), SourceChange{Source: Source{Name: "测试历史", Host: "127.0.0.1", Port: 1433, Database: "KIOHistory", Username: "read_only", Encrypt: true, UTCOffsetMinutes: 480}, Password: &pw})
	if e != nil {
		t.Fatal(e)
	}
	view, e := s.SaveScreen(context.Background(), Screen{Name: "日报", SourceID: v.ID, Kind: "hourly"})
	if e != nil {
		t.Fatal(e)
	}
	return s, v, view
}
func actor(grants authorization.Grants) context.Context {
	return authorization.WithActor(context.Background(), authorization.Actor{Grants: grants, Valid: func() bool { return true }})
}
func TestConfigRoundTripSecretsAndConflict(t *testing.T) {
	s, v, view := fixture(t)
	ctx := context.Background()
	c, e := s.load()
	if e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(c)
	if strings.Contains(string(b), "synthetic-only-test") {
		t.Fatal("plaintext stored")
	}
	public, _ := s.Sources(ctx)
	b, _ = json.Marshal(public)
	if strings.Contains(string(b), "secret") || strings.Contains(string(b), c.Sources[0].Secret) {
		t.Fatal("secret returned")
	}
	if p, e := s.password(c.Sources[0]); e != nil || p != "synthetic-only-test" {
		t.Fatal(p, e)
	}
	v.Name = "已改名"
	updated, e := s.SaveSource(ctx, SourceChange{Source: v})
	if e != nil || updated.Revision != 2 {
		t.Fatal(updated, e)
	}
	if _, e = s.SaveSource(ctx, SourceChange{Source: v}); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	if e = s.Delete(ctx, "sources", v.ID, updated.Revision); e == nil {
		t.Fatal("deleted referenced source")
	}
	view.Kind = "trend"
	if _, e = s.SaveScreen(ctx, view); e == nil {
		t.Fatal("changed granted screen dataset")
	}
	if e = s.Delete(ctx, "screens", view.ID, view.Revision); e != nil {
		t.Fatal(e)
	}
	if e = s.Delete(ctx, "sources", v.ID, updated.Revision); e != nil {
		t.Fatal(e)
	}
}
func TestIndependentScope(t *testing.T) {
	s, v, view := fixture(t)
	all := actor(authorization.Grants{Roles: []string{"viewer"}, AllStations: true})
	if list, e := s.Screens(all); e != nil || len(list) != 0 {
		t.Fatal(list, e)
	}
	if _, e := s.Sources(all); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	if _, _, e := s.source(all, view.ID, true); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	granted := actor(authorization.Grants{Roles: []string{"viewer"}, ExternalScreenIDs: []string{view.ID}})
	if _, _, e := s.source(granted, view.ID, true); e != nil {
		t.Fatal(e)
	}
	if _, e := s.SaveSource(granted, SourceChange{Source: v}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	admin := actor(authorization.Grants{Roles: []string{"admin"}, AllStations: true})
	if list, e := s.Screens(admin); e != nil || len(list) != 1 {
		t.Fatal(list, e)
	}
	if _, _, e := s.source(admin, view.ID, true); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
	expired := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: []string{"engineer"}, AllStations: true}, Valid: func() bool { return false }})
	if _, e := s.Sources(expired); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
}
func TestKeyRecoveryAndCredentialTampering(t *testing.T) {
	s, _, _ := fixture(t)
	c, _ := s.load()
	changed := c.Sources[0]
	changed.ID = "other-source"
	if _, e := s.password(changed); e == nil {
		t.Fatal("secret accepted on different source")
	}
	dir := t.TempDir()
	s2, e := Open(s.repo, dir)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s2.password(c.Sources[0]); e == nil {
		t.Fatal("foreign key decrypted")
	}
	if e = os.WriteFile(filepath.Join(dir, "connection.key"), []byte("invalid"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = Open(s.repo, dir); e == nil {
		t.Fatal("accepted broken key")
	}
}
func mockDB(t *testing.T, s *Service) sqlmock.Sqlmock {
	t.Helper()
	db, m, e := sqlmock.New()
	if e != nil {
		t.Fatal(e)
	}
	s.open = func(context.Context, Source, string) (*sql.DB, error) { return db, nil }
	t.Cleanup(func() {
		if e := m.ExpectationsWereMet(); e != nil {
			t.Error(e)
		}
	})
	return m
}
func mapping(m sqlmock.Sqlmock, station string, column string) {
	m.ExpectQuery("SELECT TOP \\(61\\)").WithArgs(station).WillReturnRows(sqlmock.NewRows([]string{"PointCode", "PointName", "Unit", "SampleColumn", "ValueType"}).AddRow("T1", "一次网_供水温度", "℃", column, "N"))
}
func TestHourlyPreservesPrecisionQualityAndMissing(t *testing.T) {
	s, _, view := fixture(t)
	m := mockDB(t, s)
	mapping(m, "A", "Value01")
	start := time.Date(2026, 10, 26, 16, 0, 0, 0, time.UTC)
	m.ExpectQuery("WITH Hours").WithArgs("A", start).WillReturnRows(sqlmock.NewRows([]string{"target", "sample", "quality", "value"}).AddRow(start, start, 1, "123456789012345.123456").AddRow(start.Add(time.Hour), start.Add(time.Hour-time.Minute), 0, "99").AddRow(start.Add(2*time.Hour), nil, nil, nil))
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, Request{Station: "A", Date: "2026-10-27"})
	if e != nil {
		t.Fatal(e)
	}
	if *r.Rows[0].Values[0] != "123456789012345.123456" || r.Rows[0].TargetTime != "2026-10-27T00:00:00+08:00" || r.Rows[1].Values[0] != nil || r.Rows[1].Match != "nearest" || r.Rows[2].Match != "missing" || r.Rows[2].SampleTime != nil {
		t.Fatalf("%+v", r)
	}
}
func TestDetailBoundedPagingAndParameters(t *testing.T) {
	s, source, _ := fixture(t)
	view, e := s.SaveScreen(context.Background(), Screen{Name: "明细", SourceID: source.ID, Kind: "detail"})
	if e != nil {
		t.Fatal(e)
	}
	m := mockDB(t, s)
	station := "A';DROP TABLE x--"
	mapping(m, station, "Value60")
	start := time.Date(2026, 10, 26, 16, 0, 0, 0, time.UTC)
	rows := sqlmock.NewRows([]string{"target", "sample", "quality", "value"})
	for i := 0; i < 501; i++ {
		at := start.Add(time.Duration(i) * time.Minute)
		rows.AddRow(at, at, 2, "12.500")
	}
	m.ExpectQuery("SELECT sample.SampleTime").WithArgs(station, start, start.Add(24*time.Hour), 500).WillReturnRows(rows)
	m.ExpectClose()
	r, e := s.Query(context.Background(), view.ID, Request{Station: station, From: "2026-10-27T00:00", To: "2026-10-28T00:00", Offset: 500})
	if e != nil || len(r.Rows) != 500 || !r.HasMore || r.Offset != 500 {
		t.Fatal(len(r.Rows), r.HasMore, e)
	}
}
func TestInvalidMappingNeverBecomesSQL(t *testing.T) {
	s, _, view := fixture(t)
	m := mockDB(t, s)
	mapping(m, "A", "Value01];DELETE x--")
	m.ExpectClose()
	if _, e := s.Query(context.Background(), view.ID, Request{Station: "A", Date: "2026-10-27"}); e == nil {
		t.Fatal("accepted unsafe mapping")
	}
}
func TestValidationBeforeNetworkAndConcurrencyBound(t *testing.T) {
	s, _, view := fixture(t)
	calls := 0
	s.open = func(context.Context, Source, string) (*sql.DB, error) {
		calls++
		return nil, errors.New("password=SECRET")
	}
	for _, r := range []Request{{Station: "A", Date: "bad"}, {Date: "2026-10-27"}, {Station: "A", Date: "2026-10-27", Offset: 999999}} {
		if _, e := s.Query(context.Background(), view.ID, r); e == nil {
			t.Fatal("invalid query accepted")
		}
	}
	if calls != 0 {
		t.Fatal("network before validation")
	}
	_, e := s.Query(context.Background(), view.ID, Request{Station: "A", Date: "2026-10-27"})
	if e == nil || strings.Contains(e.Error(), "SECRET") {
		t.Fatal(e)
	}
	for i := 0; i < cap(s.slots); i++ {
		s.slots <- struct{}{}
	}
	_, e = s.Query(context.Background(), view.ID, Request{Station: "A", Date: "2026-10-27"})
	if e == nil || !strings.Contains(e.Error(), "繁忙") || calls != 1 {
		t.Fatal(e, calls)
	}
}
func TestRevocationDuringQueryDiscardsResult(t *testing.T) {
	s, _, view := fixture(t)
	valid := true
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{ExternalScreenIDs: []string{view.ID}}, Valid: func() bool { return valid }})
	m := mockDB(t, s)
	original := s.open
	s.open = func(ctx context.Context, v Source, p string) (*sql.DB, error) {
		db, e := original(ctx, v, p)
		valid = false
		return db, e
	}
	mapping(m, "A", "Value01")
	m.ExpectQuery("WITH Hours").WillReturnRows(sqlmock.NewRows([]string{"target", "sample", "quality", "value"}))
	m.ExpectClose()
	if _, e := s.Query(ctx, view.ID, Request{Station: "A", Date: "2026-10-27"}); !errors.Is(e, authorization.ErrDenied) {
		t.Fatal(e)
	}
}
