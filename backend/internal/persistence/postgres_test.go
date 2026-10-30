package persistence_test

import (
	"context"
	"fmt"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
	"github.com/YufeiSun5/universal-hmi/backend/internal/identity"
	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/process"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

func TestBind(t *testing.T) {
	q := `SELECT '?' AS "?", 'it''s?' WHERE a=? AND b=?`
	want := `SELECT '?' AS "?", 'it''s?' WHERE a=$1 AND b=$2`
	if persistence.Bind(q, true) != want || persistence.Bind(q, false) != q {
		t.Fatal("placeholder quoting")
	}
}

func TestPostgreSQLMigrationAndDomainContracts(t *testing.T) {
	config := os.Getenv("HMI_PG_TEST_CONFIG")
	if config == "" {
		t.Skip("set HMI_PG_TEST_CONFIG for real PostgreSQL integration")
	}
	dsn, e := persistence.ConfigFile(config)
	must(t, e)
	admin, e := persistence.Open("", dsn)
	must(t, e)
	defer admin.Close()
	schema := fmt.Sprintf("hmi_test_%d", time.Now().UnixNano())
	_, e = admin.Exec("CREATE SCHEMA " + schema)
	must(t, e)
	defer func() { _, e := admin.Exec("DROP SCHEMA " + schema + " CASCADE"); must(t, e) }()
	u, e := url.Parse(dsn)
	must(t, e)
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	dsn = u.String()
	dir := t.TempDir()
	ctx := context.Background()
	old, e := storage.Open(dir)
	must(t, e)
	now := time.Now().UTC()
	must(t, old.Append(ctx, []storage.Sample{{PointID: "p1", Station: "A", Name: "温度", Value: 12.5, Raw: 125, Unit: "°C", Quality: "good", SourceTime: now, ReceivedTime: now, Version: "old"}}))
	must(t, old.SaveConfig("page_navigation", map[string]any{"revision": 7}))
	must(t, old.Close())
	securityDir := filepath.Join(dir, "security")
	oldID, e := identity.Open(securityDir)
	must(t, e)
	const password = "integration password over fifteen"
	owner, e := oldID.Bootstrap("owner", password)
	must(t, e)
	must(t, oldID.RegisterStations([]string{"A", "B"}))
	legacyRole, e := oldID.ChangeRole(oldID.Actor(owner), "", identity.Role{Name: "Migrated role", Grants: authorization.Grants{Roles: []string{"viewer"}, Export: true}}, nil, false)
	must(t, e)
	legacyMember, e := oldID.Change(oldID.Actor(owner), "", identity.Change{Username: "legacy-role-user", Password: password, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{oldID.StationID("A")}}, CustomRoleIDs: []string{legacyRole.ID}})
	must(t, e)
	must(t, oldID.Close())
	oldPoints, e := points.Open(filepath.Join(dir, "points.json"))
	must(t, e)
	_, e = oldPoints.Create(points.CreateInput{Station: "A", Name: "温度", DataType: "FLOAT", SourceType: "manual"})
	must(t, e)
	oldScreens, e := process.Open(filepath.Join(dir, "screens"))
	must(t, e)
	original, e := oldScreens.Save(process.Document{SchemaVersion: 1, ID: "screen-a", Name: "A", Station: "A", Width: 800, Height: 600})
	must(t, e)
	store, e := storage.OpenDatabase(dir, dsn)
	must(t, e)
	defer store.Close()
	docs, e := persistence.NewDocuments(store.DB)
	must(t, e)
	ids, e := identity.OpenDatabase(securityDir, dsn)
	must(t, e)
	defer ids.Close()
	lease, e := store.DB.Lease(ctx)
	must(t, e)
	defer lease.Close()
	if c, e := store.DB.Lease(ctx); e == nil {
		c.Close()
		t.Fatal("second backend acquired lease")
	}
	// A document-read failure after SQL rows were copied must roll back all rows.
	pointFile := filepath.Join(dir, "points.json")
	must(t, os.Rename(pointFile, pointFile+".saved"))
	must(t, os.Mkdir(pointFile, 0700))
	if _, err := persistence.ImportLegacy(ctx, dir, store.DB); err == nil {
		t.Fatal("failed source import committed")
	}
	var remaining int
	must(t, store.DB.QueryRow("SELECT count(*) FROM users").Scan(&remaining))
	if remaining != 0 {
		t.Fatal("migration rollback left users")
	}
	must(t, os.Remove(pointFile))
	must(t, os.Rename(pointFile+".saved", pointFile))
	counts, e := persistence.ImportLegacy(ctx, dir, store.DB)
	must(t, e)
	if counts["samples"] != 1 || counts["users"] != 2 || counts["screens"] != 1 {
		t.Fatal(counts)
	}
	if _, e = persistence.ImportLegacy(ctx, dir, store.DB); e == nil {
		t.Fatal("migration overwrote populated target")
	}
	got, _, token, e := ids.Login("owner", password, "one", true)
	must(t, e)
	if got.ID != owner.ID {
		t.Fatal("identity changed")
	}
	a := ids.Actor(got)
	roles, e := ids.Roles(a)
	must(t, e)
	if len(roles) != 1 || roles[0].ID != legacyRole.ID || roles[0].Members != 1 {
		t.Fatal("custom role migration lost definition or membership")
	}
	legacyGot, e := ids.User(legacyMember.ID)
	must(t, e)
	if !legacyGot.Grants.Export || ids.Actor(legacyGot).Station("B") {
		t.Fatal("custom role migration changed effective scope")
	}
	reader, e := ids.Change(a, "", identity.Change{Username: "reader", Password: password, Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{ids.StationID("A")}}})
	must(t, e)
	actor := ids.Actor(reader)
	if !actor.Station("A") || actor.Station("B") || actor.Grants.Develop() {
		t.Fatal("scope changed")
	}
	_, e = ids.Change(a, reader.ID, identity.Change{Username: reader.Username, Disabled: true, Version: reader.Version, Grants: reader.Grants})
	must(t, e)
	if actor.Active() {
		t.Fatal("revoked PG actor remained active")
	}
	if _, _, e = ids.Resolve(token, false); e != nil {
		t.Fatal(e)
	}
	ps, e := points.OpenDocuments("", docs)
	must(t, e)
	if len(ps.List()) != 1 {
		t.Fatal("point migration")
	}
	screens, e := process.OpenDocuments(filepath.Join(dir, "new-screens"), docs)
	must(t, e)
	d, e := screens.Get(original.ID)
	must(t, e)
	if d.Revision != original.Revision {
		t.Fatal("revision changed")
	}
	d.Name = "edited"
	saved, e := screens.Save(d)
	must(t, e)
	if _, e = screens.Save(d); e != process.ErrConflict {
		t.Fatal("lost update accepted", e)
	}
	screens, e = process.OpenDocuments(filepath.Join(dir, "other"), docs)
	must(t, e)
	d, e = screens.Get(saved.ID)
	must(t, e)
	if d.Name != "edited" {
		t.Fatal("PG document did not persist")
	}
	boundary, e := store.Boundary()
	must(t, e)
	must(t, store.Append(ctx, []storage.Sample{{PointID: "p1", Station: "A", Name: "温度", Value: 999, Raw: 999, Quality: "bad", SourceTime: now, ReceivedTime: now, Version: "new"}}))
	stats, e := store.Stats(ctx, storage.Filter{Before: boundary})
	must(t, e)
	if stats.Count != 1 || stats.Mean == nil || *stats.Mean != 12.5 {
		t.Fatal("snapshot changed", stats)
	}
	rows, e := store.Query(ctx, storage.Filter{Limit: 10})
	must(t, e)
	if len(rows) != 2 || rows[1].Seq <= boundary {
		t.Fatal("sequence not advanced")
	}
	_, e = store.AppendOnce(ctx, "once", []byte(`{"done":true}`), nil)
	must(t, e)
	prior, e := store.AppendOnce(ctx, "once", []byte(`{"done":false}`), nil)
	must(t, e)
	if string(prior) != `{"done":true}` {
		t.Fatal("idempotency lost")
	}
	beforeFailure, e := store.Boundary()
	must(t, e)
	if e = store.Append(ctx, []storage.Sample{{PointID: "p1", Value: 1, Raw: 1}, {PointID: "p1", Value: math.NaN()}}); e == nil {
		t.Fatal("invalid batch accepted")
	}
	afterFailure, e := store.Boundary()
	must(t, e)
	if beforeFailure != afterFailure {
		t.Fatal("partial sample batch committed")
	}
	var workers sync.WaitGroup
	failures := make(chan error, 2)
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			_, e := store.AppendOnce(ctx, "concurrent", []byte(`{"done":true}`), []storage.Sample{{PointID: "once", Value: 1, Raw: 1}})
			failures <- e
		}()
	}
	workers.Wait()
	close(failures)
	for e := range failures {
		must(t, e)
	}
	onceRows, e := store.Query(ctx, storage.Filter{PointID: "once", Limit: 10})
	must(t, e)
	if len(onceRows) != 1 {
		t.Fatal("concurrent retry duplicated samples")
	}
	must(t, screens.Delete(d.ID, d.Revision))
	if _, e = screens.Get(d.ID); e != process.ErrNotFound {
		t.Fatal("delete did not persist")
	}
}
func must(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}
