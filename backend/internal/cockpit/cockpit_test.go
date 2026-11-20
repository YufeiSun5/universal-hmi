package cockpit

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/overview"
	"github.com/YufeiSun5/universal-hmi/backend/internal/projectsecret"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

type snapshot []storage.Sample

type rankHistorySource struct{}

func (rankHistorySource) CockpitAccess(context.Context, string) (string, error) {
	return "rank-source", nil
}

func (rankHistorySource) CockpitHistory(context.Context, string, string, []string, time.Time) (map[string]any, error) {
	return nil, nil
}

func (s snapshot) SubscriptionSnapshot(context.Context, []string) (map[string]any, error) {
	return map[string]any{"values": []storage.Sample(s)}, nil
}

func TestRankDisplayNamesSurviveLegacySavesAndCanBeCleared(t *testing.T) {
	store, err := storage.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	service := New(store, rankHistorySource{}, nil, "", "", nil)
	initial, err := service.Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	initial.EnergyScreen = "energy"
	initial.RankNames = map[string]string{"01-001": " 中心供热站 "}
	saved, err := service.Save(ctx, ConfigChange{Config: initial.Config})
	if err != nil {
		t.Fatal(err)
	}
	saved.RankNames = nil
	saved, err = service.Save(ctx, ConfigChange{Config: saved.Config})
	if err != nil {
		t.Fatal(err)
	}
	history, err := service.History(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if aliases := history["rank_names"].(map[string]string); aliases["01-001"] != "中心供热站" {
		t.Fatalf("unexpected rank names: %v", aliases)
	}
	saved.RankNames = map[string]string{}
	cleared, err := service.Save(ctx, ConfigChange{Config: saved.Config})
	if err != nil || len(cleared.RankNames) != 0 {
		t.Fatalf("name was not cleared: %+v, %v", cleared, err)
	}
}

func TestLiveUsesSecondaryConditionsAndPrimarySupplyTotals(t *testing.T) {
	store, err := storage.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	row := overview.Row{ID: "row", Site: "中心所", Name: "中心站", Bindings: map[string]string{
		"power": "power-point", "primary-supply": "primary-supply-point",
		"secondary-power": "secondary-power-point", "supply": "supply-point",
		"return": "return-point", "supply-pressure": "supply-pressure-point",
		"return-pressure": "return-pressure-point", "flow": "flow-point",
	}}
	if err := store.SaveConfig(overview.ConfigKey, overview.Config{
		Columns: []overview.Column{
			{ID: "power", Group: "一次网", Name: "一次网瞬时热量", Unit: "GJ/h"},
			{ID: "primary-supply", Group: "一次网", Name: "高温水供水温度", Unit: "℃"},
			{ID: "secondary-power", Group: "二次网", Name: "二网热量瞬时值", Unit: "GJ/h"},
			{ID: "supply", Group: "二次网", Name: "二网供水温度", Unit: "℃"},
			{ID: "return", Group: "二次网", Name: "二网回水温度", Unit: "℃"},
			{ID: "supply-pressure", Group: "二次网", Name: "二网供水压力", Unit: "MPa"},
			{ID: "return-pressure", Group: "二次网", Name: "二网回水压力", Unit: "MPa"},
			{ID: "flow", Group: "二次网", Name: "二网供水流量", Unit: "t/h"},
		},
		Rows: []overview.Row{row},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveConfig(ConfigKey, Config{PowerRows: []string{row.ID}}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Add(-time.Second)
	samples := snapshot{
		{PointID: "power-point", Value: 36.0, Quality: "good", SourceTime: now},
		{PointID: "primary-supply-point", Value: 70.3, Quality: "good", SourceTime: now},
		{PointID: "secondary-power-point", Value: 18.0, Quality: "good", SourceTime: now},
		{PointID: "supply-point", Value: 51.0, Quality: "good", SourceTime: now},
		{PointID: "return-point", Value: 41.0, Quality: "good", SourceTime: now},
		{PointID: "supply-pressure-point", Value: 0.5, Quality: "good", SourceTime: now},
		{PointID: "return-pressure-point", Value: 0.3, Quality: "good", SourceTime: now},
		{PointID: "flow-point", Value: 120.0, Quality: "good", SourceTime: now},
	}
	service := New(store, nil, samples, "", "", nil)
	result, err := service.Live(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	rows := result["rows"].([]map[string]any)
	power := rows[0]["power"].(map[string]any)
	supply := rows[0]["supply_temp"].(map[string]any)
	groups := result["groups"].([]map[string]any)
	if result["power"] != 10.0 || groups[0]["power"] != 10.0 ||
		power["value"] != 5.0 || power["unit"] != "MW" || supply["value"] != 51.0 || supply["unit"] != "℃" {
		t.Fatalf("unexpected live result: %+v", result)
	}

	for key, want := range map[string]float64{"return_temp": 41, "supply_pressure": 0.5, "return_pressure": 0.3, "flow": 120} {
		if got := rows[0][key].(map[string]any)["value"]; got != want {
			t.Errorf("%s=%v; want %v", key, got, want)
		}
	}
	samples[2].Quality = "bad"
	missing, err := service.Live(context.Background())
	if err != nil || missing["rows"].([]map[string]any)[0]["power"] != nil || missing["power"] != 10.0 {
		t.Fatalf("invalid secondary reading or primary fallback: %+v, %v", missing, err)
	}

	// An explicitly configured point unit still takes precedence.
	samples[0].Unit = "MW"
	result, err = service.Live(context.Background())
	if err != nil || result["power"] != 36.0 {
		t.Fatalf("explicit unit result: %+v, %v", result, err)
	}
	samples[0].Quality = "bad"
	result, err = service.Live(context.Background())
	if err != nil || result["power"] != nil {
		t.Fatalf("bad sample counted: %+v, %v", result, err)
	}
}

func TestQWeatherAcceptsOfficialHostForms(t *testing.T) {
	for _, host := range []string{"abc123.qweatherapi.com", "h2a9cf3mhs.xy.qweatherapi.com"} {
		if qweather(host, "test-key") == nil {
			t.Errorf("rejected %q", host)
		}
	}
	for _, host := range []string{"xyz.qweatherapi.com.example.net", "qweatherapi.com", "a..qweatherapi.com", "https://xyz.qweatherapi.com"} {
		if qweather(host, "test-key") != nil {
			t.Errorf("accepted %q", host)
		}
	}
}

type weatherTransport func(*http.Request) (*http.Response, error)

func (f weatherTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestWeatherSettingsPersistPrivatelyAndDriveTheProvider(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	store, err := storage.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	path := filepath.Join(dir, "cockpit", "weather.key")
	secret, err := projectsecret.OpenFile(path)
	if err != nil {
		t.Fatal(err)
	}
	service := New(store, nil, nil, "old.qweatherapi.com", "legacy-key", secret)
	initial, err := service.Get(ctx)
	if err != nil || initial.WeatherHost != "old.qweatherapi.com" || !initial.HasWeatherKey {
		t.Fatalf("legacy settings unavailable: %+v, %v", initial, err)
	}
	host, key := "account.xy.qweatherapi.com", "test-weather-key"
	lat, lon := 39.7, 122.97
	initial.Latitude, initial.Longitude = &lat, &lon
	change := ConfigChange{Config: initial.Config, WeatherHost: &host, WeatherKey: &key}
	saved, err := service.Save(ctx, change)
	if err != nil || saved.WeatherHost != host || !saved.HasWeatherKey {
		t.Fatalf("failed to save settings: %+v, %v", saved, err)
	}
	response, err := json.Marshal(saved)
	if err != nil || strings.Contains(string(response), key) || strings.Contains(string(response), `"secret"`) {
		t.Fatal("a save response exposed the credentials")
	}
	var raw json.RawMessage
	if err := store.LoadConfig(ConfigKey, &raw); err != nil || strings.Contains(string(raw), key) {
		t.Fatal("the settings were not stored as ciphertext")
	}

	secret, err = projectsecret.OpenFile(path)
	if err != nil {
		t.Fatal(err)
	}
	service = New(store, nil, nil, "", "", secret)
	after, err := service.Save(ctx, ConfigChange{Config: saved.Config})
	if err != nil || !after.HasWeatherKey || after.WeatherHost != host {
		t.Fatalf("saving old client fields lost the credentials: %+v, %v", after, err)
	}
	badHost := "wrong.xy.qweatherapi.com"
	if _, err := service.Save(ctx, ConfigChange{Config: after.Config, WeatherHost: &badHost}); err == nil {
		t.Fatal("the old key could be forwarded to another account")
	}
	transport := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = transport })
	requests := 0
	http.DefaultTransport = weatherTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != host || r.Header.Get("X-QW-Api-Key") != key {
			t.Error("weather request used the wrong account")
		}
		requests++
		fixture := `{}`
		switch {
		case strings.Contains(r.URL.Path, "/current/"):
			fixture = `{"temperature":{"value":2.1,"unit":"°C"},"condition":{"text":"晴"}}`
		case strings.Contains(r.URL.Path, "/hourly/"):
			fixture = `{"hours":[{"forecastTime":"2026-11-19T08:00Z","temperature":{"value":1.8,"unit":"°C"}}]}`
		case strings.Contains(r.URL.Path, "/daily/"):
			fixture = `{"days":[{"forecastStartTime":"2026-11-19T22:00Z","temperatureMin":{"value":-3,"unit":"°C"}}]}`
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(fixture))}, nil
	})
	now := time.Date(2026, 11, 19, 7, 50, 0, 0, time.UTC)
	service.refresh(ctx, now)
	service.refresh(ctx, now.Add(time.Minute))
	weather, err := service.Weather(ctx)
	current, _ := weather["current"].(*float64)
	hours, _ := weather["hourly"].([]*float64)
	days, _ := weather["daily"].([]map[string]any)
	if err != nil || requests != 3 || current == nil || *current != 2.1 ||
		len(hours) != 24 || hours[0] == nil || *hours[0] != 1.8 || len(days) != 1 {
		t.Fatalf("weather data or cache is wrong: %+v, %d requests, %v", weather, requests, err)
	}
	clearHost := ""
	cleared, err := service.Save(ctx, ConfigChange{Config: after.Config, WeatherHost: &clearHost})
	if err != nil || cleared.HasWeatherKey || cleared.WeatherHost != "" {
		t.Fatalf("failed to clear the weather account: %+v, %v", cleared, err)
	}
}
