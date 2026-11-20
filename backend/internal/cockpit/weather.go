package cockpit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var weatherHost = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+qweatherapi\.com$`)

func validWeatherHost(host string) bool {
	return len(host) <= 253 && weatherHost.MatchString(host)
}

type weatherValue struct {
	Value *float64 `json:"value"`
	Unit  string   `json:"unit"`
}

type condition struct {
	Text string `json:"text"`
}

func weatherTime(raw string) time.Time {
	at, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		at, _ = time.Parse("2006-01-02T15:04Z07:00", raw)
	}
	return at
}

func qweather(host, credential string) func(context.Context, float64, float64, time.Time) (map[string]any, error) {
	host = strings.ToLower(strings.TrimSpace(host))
	credential = strings.TrimSpace(credential)
	if !validWeatherHost(host) || credential == "" {
		return nil
	}
	client := &http.Client{
		Timeout: 8 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return func(ctx context.Context, latitude, longitude float64, now time.Time) (map[string]any, error) {
		location := fmt.Sprintf("/%.2f/%.2f", latitude, longitude)
		fetch := func(part string, params url.Values, out any) error {
			u := url.URL{Scheme: "https", Host: host, Path: "/weather/v1/" + part + location, RawQuery: params.Encode()}
			r, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
			if err != nil {
				return err
			}
			r.Header.Set("X-QW-Api-Key", credential)
			response, err := client.Do(r)
			if err != nil {
				return errors.New("天气服务连接失败")
			}
			defer response.Body.Close()
			switch response.StatusCode {
			case http.StatusOK:
			case http.StatusUnauthorized, http.StatusForbidden:
				return errors.New("天气服务认证失败，请核对 API Host、密钥和接口权限")
			default:
				return fmt.Errorf("天气服务请求失败（HTTP %d）", response.StatusCode)
			}
			if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(out); err != nil {
				return errors.New("天气服务返回格式有误")
			}
			return nil
		}
		var hourly struct {
			Hours []struct {
				Time      string       `json:"forecastTime"`
				Temp      weatherValue `json:"temperature"`
				Condition condition    `json:"condition"`
			} `json:"hours"`
		}
		if err := fetch("hourly", url.Values{"hours": {"25"}, "lang": {"zh"}}, &hourly); err != nil {
			return nil, err
		}
		var daily struct {
			Days []struct {
				Start string       `json:"forecastStartTime"`
				Min   weatherValue `json:"temperatureMin"`
				Max   weatherValue `json:"temperatureMax"`
				Day   struct {
					Condition condition `json:"condition"`
				} `json:"daytime"`
			} `json:"days"`
		}
		if err := fetch("daily", url.Values{"days": {"4"}, "lang": {"zh"}}, &daily); err != nil {
			return nil, err
		}
		var current struct {
			Temp      weatherValue `json:"temperature"`
			Condition condition    `json:"condition"`
		}
		_ = fetch("current", url.Values{"lang": {"zh"}}, &current)
		out := map[string]any{"at": now, "source": "和风天气"}
		if current.Temp.Unit == "°C" && current.Temp.Value != nil {
			out["current"] = current.Temp.Value
			out["condition"] = current.Condition.Text
		}
		values := make([]*float64, 24)
		first := now.UTC().Truncate(time.Hour).Add(time.Hour)
		var lowest *float64
		var lowAt time.Time
		today := now.In(cst).Format("2006-01-02")
		for _, row := range hourly.Hours {
			at := weatherTime(row.Time)
			i := int(at.Sub(first) / time.Hour)
			if at.Before(first) || i >= len(values) || row.Temp.Value == nil || row.Temp.Unit != "°C" {
				continue
			}
			values[i] = row.Temp.Value
			local := at.In(cst)
			tonight := local.Format("2006-01-02") == today && local.Hour() >= 19 ||
				local.Format("2006-01-02") == now.In(cst).AddDate(0, 0, 1).Format("2006-01-02") && local.Hour() < 7
			if tonight && (lowest == nil || *row.Temp.Value < *lowest) {
				lowest, lowAt = row.Temp.Value, at
			}
		}
		if lowest != nil {
			out["night"], out["night_at"] = lowest, lowAt
		}
		labels := []string{}
		for _, n := range []int{0, 6, 12, 18, 23} {
			labels = append(labels, first.Add(time.Duration(n)*time.Hour).In(cst).Format("15:04"))
		}
		days := []map[string]any{}
		for _, row := range daily.Days {
			at := weatherTime(row.Start)
			if at.IsZero() || at.In(cst).Format("2006-01-02") <= today || len(days) == 3 {
				continue
			}
			days = append(days, map[string]any{"low": row.Min.Value, "high": row.Max.Value, "condition": row.Day.Condition.Text})
		}
		out["hourly"], out["labels"], out["daily"] = values, labels, days
		return out, nil
	}
}
