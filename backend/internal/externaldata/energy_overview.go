package externaldata

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

// EnergyOverview is the same projection displayed in the cockpit and the current overview.
type EnergyOverview struct {
	At     time.Time           `json:"at"`
	Values map[string]*float64 `json:"values"`
}

type energySnapshot struct {
	at      time.Time
	current []Statistic
	cockpit map[string]any
}

type currentEnergyCache struct {
	mu      sync.Mutex
	entries map[string]*energySnapshot
	loads   singleflight.Group
}

func (c *currentEnergyCache) lookup(key string) *energySnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.entries[key]
}

func (s *Service) currentEnergy(ctx context.Context, source storedSource, now time.Time) (*energySnapshot, error) {
	at := now.UTC().Truncate(time.Minute)
	cache := &s.energyToday
	key := fmt.Sprintf("%s/%d/%d", source.ID, source.Revision, at.Unix())
	if snapshot := cache.lookup(key); snapshot != nil {
		return snapshot, ctx.Err()
	}
	load := cache.loads.DoChan(key, func() (any, error) {
		if snapshot := cache.lookup(key); snapshot != nil {
			return snapshot, nil
		}
		// One caller leaving the page must not cancel the snapshot for the other.
		queryCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		db, release, err := s.database(queryCtx, source)
		if err != nil {
			return nil, err
		}
		defer release()
		local := at.In(beijing)
		day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, beijing)
		rows, err := cockpitStats(queryCtx, db, true, day, at)
		if err != nil {
			return nil, err
		}
		latest := latestEnergyStatistics(rows)
		dailyRows := make([]Statistic, 0, len(latest)*len(cockpitUsageUnits))
		for _, stations := range latest {
			for _, row := range stations {
				dailyRows = append(dailyRows, businessEnergyStatistic(row))
			}
		}
		sort.Slice(dailyRows, func(i, j int) bool {
			return dailyRows[i].Station+"/"+dailyRows[i].Metric < dailyRows[j].Station+"/"+dailyRows[j].Metric
		})
		snapshot := &energySnapshot{
			at: at, current: dailyRows,
			cockpit: projectCockpitTotals(rows, latest, day, at, local.Hour()),
		}
		cache.mu.Lock()
		defer cache.mu.Unlock()
		if cache.entries == nil {
			cache.entries = make(map[string]*energySnapshot)
		}
		for id, previous := range cache.entries {
			if previous.at.Before(at.Add(-time.Minute)) {
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
		return result.Val.(*energySnapshot), nil
	}
}

// A statistic for the last returned hour contains the day-to-date total.
func latestEnergyStatistics(rows []Statistic) map[string]map[string]Statistic {
	latest := map[string]map[string]Statistic{}
	for _, row := range rows {
		metric := energyMetric(row.Label)
		if metric == "" || row.Hour == nil {
			continue
		}
		if latest[metric] == nil {
			latest[metric] = map[string]Statistic{}
		}
		old := latest[metric][row.Station]
		if old.Hour == nil || *old.Hour < *row.Hour {
			row.Metric = metric
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
