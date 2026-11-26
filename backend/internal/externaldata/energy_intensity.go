package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var energyZoneCode = regexp.MustCompile(`^[0-9]{2}-[0-9]{3}-[0-9]{2}$`)

const EnergyIntensitySeasonTimeout = 2 * time.Minute

func energyWaterZones(directory []Station, site string) []Station {
	zones := []Station{}
	for _, station := range directory {
		if energyZoneCode.MatchString(station.Code) && (site == "" || station.Code[:6] == site) {
			zones = append(zones, station)
		}
	}
	return zones
}

// SetEnergyAreas connects the project's shared area configuration at startup.
func (s *Service) SetEnergyAreas(read func() (CockpitAreas, error)) {
	s.energyAreas = read
}

func energyPeriodRow(station Station, metric string) Statistic {
	units := map[string]string{"heat": "GJ", "electricity": "kWh", "water": "t"}
	return Statistic{Station: station.Code, Name: station.Name, Metric: metric, Unit: units[metric]}
}

func intensityBounds(in Request, now time.Time) (time.Time, time.Time, error) {
	in.Mode = "daily"
	switch in.Period {
	case "", "range", "daily":
		if in.Period == "daily" {
			in.From, in.To = "", ""
		}
		start, end, _, err := statisticsBounds("energy", in, now)
		return start, end, err
	case "monthly", "season":
		if in.Station != "" && !siteCode.MatchString(in.Station) {
			return time.Time{}, time.Time{}, fmt.Errorf("请选择有效整站")
		}
		start, end, err := heatSettlementBounds(Request{Mode: "settlement_" + in.Period, Date: in.Date, Offset: in.Offset}, now)
		if err != nil {
			return start, end, err
		}
		first, _ := time.ParseInLocation("2006-01-02", periodStart, beijing)
		year, month, day := now.In(beijing).Date()
		today := time.Date(year, month, day, 0, 0, 0, 0, beijing)
		if end.Before(first) {
			return start, end, fmt.Errorf("请选择2026-11-04起有统计数据的周期")
		}
		if start.Before(first) {
			start = first
		}
		if end.After(today) {
			end = today
		}
		return start, end, nil
	default:
		return time.Time{}, time.Time{}, fmt.Errorf("请选择日、月、采暖季或自选日期")
	}
}

func (s *Service) queryEnergyIntensity(ctx context.Context, source storedSource, view Screen, in Request, now time.Time) (Result, error) {
	switch in.Metric {
	case "", "heat", "water", "electricity":
	default:
		return Result{}, fmt.Errorf("请选择热、水或电单耗")
	}
	if !mayReadIntensity(ctx, view, in.Metric) {
		return Result{}, authorizationDenied()
	}
	start, end, err := intensityBounds(in, now)
	if err != nil {
		return Result{}, err
	}
	var areas CockpitAreas
	if s.energyAreas != nil {
		areas, err = s.energyAreas()
		if err != nil {
			return Result{}, err
		}
	}
	timeout := 30 * time.Second
	if in.Period == "season" {
		timeout = EnergyIntensitySeasonTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	db, closeDB, err := s.database(ctx, source)
	if err != nil {
		return Result{}, err
	}
	defer closeDB()
	var directory []Station
	if in.Metric != "heat" {
		directory, err = readStationDirectory(ctx, db)
		if err != nil {
			return Result{}, err
		}
	}
	var site any
	if in.Station != "" {
		site = in.Station
	}
	var whole, water []Statistic
	var zones []Station
	if in.Metric != "water" {
		whole, err = wholePeriodStatistics(ctx, db, start, end, now, site, false, "单耗统计")
		if err != nil {
			return Result{}, err
		}
	}
	if in.Metric == "" || in.Metric == "water" {
		zones = energyWaterZones(directory, in.Station)
		water, err = readWaterUsage(ctx, db, zones, start, end)
		if err != nil {
			return Result{}, err
		}
	}
	data := intensityUsage(directory, zones, whole, water, in.Station, in.Metric)
	period := start.Format("2006-01-02")
	if in.Period == "monthly" || in.Period == "season" || !start.Equal(end) {
		period += " 至 " + end.Format("2006-01-02")
	}
	result, err := energyPeriodResult(ctx, source, view, period, data)
	if err != nil {
		return Result{}, err
	}
	applyIntensity(result.Statistics, areas)
	if !mayReadIntensity(ctx, view, in.Metric) {
		return Result{}, authorizationDenied()
	}
	return result, nil
}

func readWaterUsage(ctx context.Context, db *sql.DB, zones []Station, start, end time.Time) ([]Statistic, error) {
	if len(zones) == 0 {
		return nil, nil
	}
	names := make(map[string]string, len(zones))
	codes := make([]string, 0, len(zones))
	for _, zone := range zones {
		names[zone.Code] = zone.Name
		codes = append(codes, zone.Code)
	}
	var data []Statistic
	const limit = 25000
	// The daily procedure returns all configured fields, up to 60 per zone.
	window := min(31, max(1, limit/(60*len(codes))))
	fields := []string{"统计日期", "站区编码", "测点编码", "单位", "完整日用量"}
	for first := start; !first.After(end); first = first.AddDate(0, 0, window) {
		last := first.AddDate(0, 0, window-1)
		if last.After(end) {
			last = end
		}
		from, to := first.Format("2006-01-02"), last.Format("2006-01-02")
		rows, err := db.QueryContext(ctx, settlementProcedure, sql.Named("from", from), sql.Named("to", to), sql.Named("station", strings.Join(codes, ",")))
		if err != nil {
			return nil, interfaceError(ctx, "分区补水用量")
		}
		batch, err := scanInterfaceRows(rows, fields, limit, "+08:00")
		rows.Close()
		if err != nil {
			return nil, interfaceError(ctx, "分区补水用量")
		}
		for _, m := range batch {
			if value(m["测点编码"]) != "ER_MakeupFlowTotal" {
				continue
			}
			code := value(m["站区编码"])
			name, found := names[code]
			date, _, _ := strings.Cut(value(m["统计日期"]), "T")
			if !found || date < from || date > to {
				return nil, interfaceError(ctx, "分区补水用量")
			}
			data = append(data, Statistic{Station: code, Name: name, Date: date, Metric: "water", Unit: value(m["单位"]), DayUsage: m["完整日用量"]})
		}
	}
	return data, nil
}

func intensityUsage(directory, zones []Station, whole, water []Statistic, site, metric string) []Statistic {
	data := append([]Statistic{}, water...)
	heatNames := map[string]string{}
	for _, meter := range cockpitHeatMeters {
		if (metric == "" || metric == "heat") && (site == "" || meter.Code == site) {
			heatNames[meter.Code] = meter.Name
			data = append(data, energyPeriodRow(meter.Station, "heat"))
		}
	}
	electricNames := map[string]string{}
	for _, station := range energyStations(directory) {
		if (metric == "" || metric == "electricity") && (site == "" || station.Code == site) {
			electricNames[station.Code] = station.Name
			data = append(data, energyPeriodRow(station, "electricity"))
		}
	}
	for _, zone := range zones {
		data = append(data, energyPeriodRow(zone, "water"))
	}
	for _, r := range whole {
		var name string
		switch energyMetric(r.Metric) {
		case "heat":
			name = heatNames[r.Station]
		case "electricity":
			name = electricNames[r.Station]
		}
		if name != "" {
			r.Name = name
			r.DaySubtotal = nil
			data = append(data, r)
		}
	}
	return data
}

func applyIntensity(rows []Statistic, areas CockpitAreas) {
	byMetric := map[string]map[string]float64{"heat": areas.Heat, "electricity": areas.Electricity, "water": areas.WaterZone}
	labels := map[string]string{"heat": "热单耗", "electricity": "电单耗", "water": "水单耗"}
	for i := range rows {
		r := &rows[i]
		r.Label = labels[r.Metric]
		r.IntensityUnit = r.Unit + "/㎡"
		if area := byMetric[r.Metric][r.Station]; area > 0 {
			areaText := strconv.FormatFloat(area, 'f', -1, 64)
			denominator, valid := new(big.Rat).SetString(areaText)
			if !valid {
				continue
			}
			r.AreaM2 = &areaText
			if usage, ok := new(big.Rat).SetString(value(r.DayUsage)); ok {
				intensity := usage.Quo(usage, denominator).FloatString(12)
				r.Intensity = &intensity
			}
		}
	}
	order := map[string]int{"heat": 0, "water": 1, "electricity": 2}
	sort.SliceStable(rows, func(i, j int) bool { return order[rows[i].Metric] < order[rows[j].Metric] })
}
