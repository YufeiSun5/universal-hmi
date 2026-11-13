package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

var settlementColumn = regexp.MustCompile(`^Value(?:0[1-9]|[1-5][0-9]|60)$`)

// The deployed settlement procedure does not expose stored Min/Max. Read those
// fields and the effective statistic kind without recalculating or changing SQL.
// Identifiers come only from the validated fixed Value01..Value60 vocabulary;
// dates, station and point identities remain parameters or database joins.
func settlementRangeSQL(columns []string) (string, error) {
	values := make([]string, 0, len(columns))
	for _, c := range columns {
		if !settlementColumn.MatchString(c) {
			return "", fmt.Errorf("invalid statistic output column")
		}
		values = append(values, fmt.Sprintf("(N'%s',q.[%sMin],q.[%sMax])", c, c, c))
	}
	if len(values) == 0 || len(values) > 60 {
		return "", fmt.Errorf("invalid statistic column count")
	}
	return `;WITH days(d) AS (
 SELECT CONVERT(date,@from) UNION ALL SELECT DATEADD(day,1,d) FROM days WHERE d<CONVERT(date,@to)
)
SELECT CONVERT(varchar(10),dd.d,23) [date],s.StationCode station,p.PointCode point,w.输出列 output_column,
 x.lo day_min,x.hi day_max,
 CASE WHEN modes.n>1 THEN 'mixed' WHEN m.算差额=0 THEN 'range' WHEN m.算差额=1 THEN 'usage' ELSE 'unknown' END statistic_kind
FROM days dd
JOIN dbo.Station s ON s.StationCode=@station AND s.IsEnabled=1
JOIN dbo.Point p ON p.StationId=s.StationId AND p.IsEnabled=1
JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
LEFT JOIN dbo.日表 q ON q.StationId=s.StationId AND q.统计时间=CONVERT(datetime2(3),dd.d)
CROSS APPLY(VALUES ` + strings.Join(values, ",") + `)x(col,lo,hi)
OUTER APPLY(SELECT TOP(1) v.算差额 FROM dbo.统计测点来源 v
 WHERE v.PointId=p.PointId AND v.生效UTC<DATEADD(hour,-8,DATEADD(day,1,CONVERT(datetime2(3),dd.d)))
 ORDER BY v.生效UTC DESC)m
OUTER APPLY(SELECT COUNT(DISTINCT v.算差额)n FROM dbo.统计测点来源 v
 WHERE v.PointId=p.PointId AND v.生效UTC<DATEADD(hour,-8,DATEADD(day,1,CONVERT(datetime2(3),dd.d)))
 AND NOT EXISTS(SELECT 1 FROM dbo.统计测点来源 newer WHERE newer.PointId=v.PointId
 AND newer.生效UTC>v.生效UTC AND newer.生效UTC<=DATEADD(hour,-8,CONVERT(datetime2(3),dd.d))))modes
WHERE x.col=w.输出列
ORDER BY dd.d,p.PointCode OPTION(MAXRECURSION 31)`, nil
}

func readSettlementRanges(ctx context.Context, db *sql.DB, batch []map[string]*string, from, to, station string) (map[string]map[string]*string, error) {
	out := map[string]map[string]*string{}
	if len(batch) == 0 {
		return out, nil
	}
	columns := map[string]bool{}
	expected := map[string]string{}
	for _, m := range batch {
		column := value(m["输出列"])
		columns[column] = true
		key := strings.Split(value(m["统计日期"]), "T")[0] + "/" + value(m["站区编码"]) + "/" + value(m["测点编码"])
		if _, exists := expected[key]; exists {
			return nil, fmt.Errorf("duplicate settlement record")
		}
		expected[key] = column
	}
	names := make([]string, 0, len(columns))
	for c := range columns {
		names = append(names, c)
	}
	sort.Strings(names)
	query, err := settlementRangeSQL(names)
	if err != nil {
		return nil, err
	}
	rows, err := db.QueryContext(ctx, query, sql.Named("from", from), sql.Named("to", to), sql.Named("station", station))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	data, err := scanInterfaceRows(rows, []string{"date", "station", "point", "output_column", "day_min", "day_max", "statistic_kind"}, 25000, "+08:00")
	if err != nil {
		return nil, err
	}
	for _, m := range data {
		key := value(m["date"]) + "/" + value(m["station"]) + "/" + value(m["point"])
		if out[key] != nil || expected[key] == "" || expected[key] != value(m["output_column"]) {
			return nil, fmt.Errorf("statistic mapping changed; query again")
		}
		out[key] = m
	}
	if len(out) != len(expected) {
		return nil, fmt.Errorf("incomplete statistic range result")
	}
	return out, nil
}
