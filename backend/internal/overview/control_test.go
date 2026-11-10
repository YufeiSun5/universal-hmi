package overview

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/authorization"
)

const controlFixture = `[{"name":"新北换热站","write_enabled":true,"status":{"strategy":"workbench","mode":"AUTO","data_healthy":true,"zones":[{"id":"z1","name":"北线","write_enabled":true,"sampled_at":"2026-11-10T10:00:00+08:00","control_mode":{"state":"platform_proxy"}}],"active_settings":{"zones":[{"id":"z1","mode":"manual"}]}}}]`

func fixture(t *testing.T) []controlStation {
	t.Helper()
	var rows []controlStation
	if err := json.Unmarshal([]byte(controlFixture), &rows); err != nil {
		t.Fatal(err)
	}
	return rows
}
func TestControlStateOnlyTemperatureCurveAndTimeAreActive(t *testing.T) {
	b := ControlBinding{Station: "北换热站", Zone: "北线"}
	// Upstream manual means a temperature target, not manual valve opening.
	for _, mode := range []string{"manual", "curve", "schedule"} {
		rows := fixture(t)
		rows[0].Status.Settings.Zones[0].Mode = mode
		if got := controlState(rows, b); !got.Active || got.Label != "已接管" {
			t.Fatal(mode, got)
		}
	}
	off := false
	for _, mutate := range []func([]controlStation){
		func(r []controlStation) { r[0].WriteEnabled = &off },
		func(r []controlStation) { r[0].Status.Mode = "MANUAL" },
		func(r []controlStation) { r[0].Status.Recovery = true },
		func(r []controlStation) { r[0].Status.Zones[0].WriteEnabled = &off },
		func(r []controlStation) { r[0].Status.Zones[0].ControlMode.State = "field_auto" },
		func(r []controlStation) { r[0].Status.Zones[0].ControlMode.Suspended = true },
		func(r []controlStation) { r[0].Status.Settings.Zones[0].Mode = "idle" },
		func(r []controlStation) { r[0].Status.Settings.Zones[0].Mode = "valve" },
	} {
		r := fixture(t)
		mutate(r)
		if got := controlState(r, b); got.Active || got.Label != "未接管" {
			t.Fatal(got)
		}
	}
	for _, mutate := range []func([]controlStation){
		func(r []controlStation) { r[0].Status = nil },
		func(r []controlStation) { r[0].Name = "别站" },
		func(r []controlStation) { r[0].Status.Healthy = false },
		func(r []controlStation) { r[0].Status.Zones[0].SampledAt = "" },
		func(r []controlStation) { r[0].Status.Zones[0].ControlMode.State = "unknown" },
		func(r []controlStation) { r[0].Status.Zones = append(r[0].Status.Zones, r[0].Status.Zones[0]) },
		func(r []controlStation) { r[0].Status.Settings.Zones = nil },
		func(r []controlStation) {
			r[0].Status.Settings.Zones = append(r[0].Status.Settings.Zones, r[0].Status.Settings.Zones[0])
		},
		func(r []controlStation) { r[0].Status.Settings.Zones[0].Mode = "other" },
		func(r []controlStation) { r[0].Status.Settings.Zones[0].Mode = "auto" },
		func(r []controlStation) { r[0].Status.Settings.Zones[0].Mode = "" },
	} {
		r := fixture(t)
		mutate(r)
		if got := controlState(r, b); got.Active || got.Label != "状态未知" {
			t.Fatal(got)
		}
	}
	r := fixture(t)
	r = append(r, r[0])
	if controlState(r, b).Active {
		t.Fatal("duplicate station")
	}
	if stationKey("新华线") != "新华线" || stationKey("新南站新华线区") != "南站新华线区" {
		t.Fatal("station key")
	}
}
func controlService(t *testing.T, address string) *Service {
	t.Helper()
	s := New(&memoryStore{})
	_, err := s.Save(context.Background(), Config{Control: ControlConfig{Enabled: true, BaseURL: address}, Rows: []Row{
		{ID: "a", Name: "A", Station: "A", Control: ControlBinding{Station: "北换热站", Zone: "北线"}},
		{ID: "b", Name: "B", Station: "B", Control: ControlBinding{Station: "北换热站", Zone: "北线"}},
	}}, nil, func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	return s
}
func TestControlCoalescingFailureRecoveryAndAuthorization(t *testing.T) {
	var calls atomic.Int32
	var fail atomic.Bool
	h := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != "GET" || r.URL.Path != "/api/heatnet/overview" || len(r.Cookies()) != 0 || r.Header.Get("Authorization") != "" {
			t.Error("unsafe request", r)
		}
		if fail.Load() {
			w.WriteHeader(503)
			return
		}
		_, _ = w.Write([]byte(`{"code":0,"data":` + controlFixture + `}`))
	}))
	defer h.Close()
	s := controlService(t, h.URL)
	var valid atomic.Bool
	valid.Store(true)
	ctx := authorization.WithActor(context.Background(), authorization.Actor{Grants: authorization.Grants{Roles: []string{"viewer"}, StationIDs: []string{"A"}}, StationID: func(s string) string { return s }, Valid: valid.Load})
	var wg sync.WaitGroup
	for range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, err := s.ControlStatus(ctx)
			if err != nil || len(got.Rows) != 1 || !got.Rows["a"].Active {
				t.Error(got, err)
			}
		}()
	}
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatal("requests not coalesced", calls.Load())
	}
	cfg, err := s.Get(ctx, nil)
	if err != nil || cfg.Control.BaseURL != "" || cfg.Rows[0].Control.Station != "" {
		t.Fatal("upstream config leaked", cfg, err)
	}
	expire := func() { s.controlMu.Lock(); s.controlCache.until = time.Time{}; s.controlMu.Unlock() }
	fail.Store(true)
	expire()
	got, err := s.ControlStatus(ctx)
	if err != nil || got.Rows["a"].Active {
		t.Fatal("stale green", got, err)
	}
	fail.Store(false)
	expire()
	got, err = s.ControlStatus(ctx)
	if err != nil || !got.Rows["a"].Active {
		t.Fatal("recovery", got, err)
	}
	valid.Store(false)
	if _, err = s.ControlStatus(ctx); err == nil {
		t.Fatal("revoked reader")
	}
}
func TestControlLateResponseAndRedirect(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	h := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		_, _ = w.Write([]byte(`{"code":0,"data":` + controlFixture + `}`))
	}))
	defer h.Close()
	s := controlService(t, h.URL)
	done := make(chan ControlResult, 1)
	go func() { v, _ := s.ControlStatus(context.Background()); done <- v }()
	<-entered
	cfg, _ := s.Get(context.Background(), nil)
	cfg.Control.Enabled = false
	if _, err := s.Save(context.Background(), cfg, nil, func(string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	close(release)
	if got := <-done; got.Rows["a"].Active {
		t.Fatal("late response", got)
	}
	var targetCalls atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { targetCalls.Add(1) }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 302) }))
	defer redirect.Close()
	if fetchControl(context.Background(), redirect.URL) != nil || targetCalls.Load() != 0 {
		t.Fatal("followed redirect")
	}
	timeout := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer timeout.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if fetchControl(ctx, timeout.URL) != nil {
		t.Fatal("timeout accepted")
	}
}
func TestControlAddressValidation(t *testing.T) {
	for _, v := range []string{"http://172.16.1.7:8004", "http://127.0.0.1:1234", "https://[fd00::1]:8004/"} {
		if err := validateControl(ControlConfig{Enabled: true, BaseURL: v}); err != nil {
			t.Fatal(v, err)
		}
	}
	for _, v := range []string{"", "http://example.com", "http://8.8.8.8", "http://169.254.169.254", "http://0.0.0.0", "http://user:pass@172.16.1.7", "http://172.16.1.7/api", "http://172.16.1.7?x=1", "ftp://172.16.1.7"} {
		if validateControl(ControlConfig{Enabled: true, BaseURL: v}) == nil {
			t.Fatal(v)
		}
	}
}
