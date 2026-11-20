package externaldata

import (
	"context"
	"fmt"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

type cockpitTodaySnapshot struct {
	at     time.Time
	values map[string]any
}

type cockpitTodayCache struct {
	mu      sync.Mutex
	entries map[string]*cockpitTodaySnapshot
	loads   singleflight.Group
}

func (c *cockpitTodayCache) lookup(key string) *cockpitTodaySnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.entries[key]
}

func (s *Service) cockpitToday(ctx context.Context, source storedSource, view Screen, at time.Time) (*cockpitTodaySnapshot, error) {
	cache := &s.cockpitTodayCache
	minute := at.Truncate(time.Minute)
	key := fmt.Sprintf("%s/%d/%s/%d/%d", view.ID, view.Revision, source.ID, source.Revision, minute.Unix())
	if snapshot := cache.lookup(key); snapshot != nil {
		return snapshot, ctx.Err()
	}
	load := cache.loads.DoChan(key, func() (any, error) {
		if snapshot := cache.lookup(key); snapshot != nil {
			return snapshot, nil
		}
		queryCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		values, err := s.loadCockpitToday(queryCtx, source, view, at)
		if err != nil {
			return nil, err
		}
		snapshot := &cockpitTodaySnapshot{at: at, values: values}
		cache.mu.Lock()
		defer cache.mu.Unlock()
		if cache.entries == nil {
			cache.entries = make(map[string]*cockpitTodaySnapshot)
		}
		for id, previous := range cache.entries {
			if previous.at.Before(minute.Add(-time.Minute)) {
				delete(cache.entries, id)
			}
		}
		cache.entries[key] = snapshot
		return snapshot, nil
	})
	select {
	case <-ctx.Done():
		return nil, queryError(ctx)
	case result := <-load:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Val.(*cockpitTodaySnapshot), nil
	}
}

func (s *Service) loadCockpitToday(ctx context.Context, source storedSource, view Screen, at time.Time) (map[string]any, error) {
	current, err := s.queryStatistics(ctx, source, view, Request{Mode: "current"}, at)
	if err != nil {
		return nil, err
	}
	local := at.In(beijing)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, beijing)
	hours, hourlyErr := s.cockpitTodayHours(ctx, source, day, at)
	values := projectCockpitTotals(hours, latestEnergyStatistics(current.Statistics), day, at, local.Hour())
	if hourlyErr != nil {
		values["hourly_unavailable"] = true
	}
	return values, nil
}

func (s *Service) cockpitTodayHours(ctx context.Context, source storedSource, day, at time.Time) ([]Statistic, error) {
	db, release, err := s.database(ctx, source)
	if err != nil {
		return nil, err
	}
	defer release()
	return cockpitStats(ctx, db, true, day, at)
}

// The historical hourly response can carry multiple daily rows per site.
func latestEnergyStatistics(rows []Statistic) map[string]map[string]Statistic {
	latest := map[string]map[string]Statistic{}
	for _, row := range rows {
		metric := energyMetric(row.Label)
		if metric == "" {
			continue
		}
		if latest[metric] == nil {
			latest[metric] = map[string]Statistic{}
		}
		old, hasOld := latest[metric][row.Station]
		if !hasOld || value(old.Hour) < value(row.Hour) {
			latest[metric][row.Station] = row
		}
	}
	return latest
}

func cockpitEnergyRoster(metric string) []Station {
	if metric != "heat" {
		return CockpitEnergySites()
	}
	sites := make([]Station, 0, len(cockpitHeatMeters))
	for _, meter := range cockpitHeatMeters {
		sites = append(sites, meter.Station)
	}
	return sites
}
