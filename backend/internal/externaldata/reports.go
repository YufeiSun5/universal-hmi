package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Slot numbers are bounded before looking up the nearest sample. Equal distances
// prefer the earlier sample. No sample from outside the requested range is used.
func standardSQL(points []Point) string {
	return `WITH D(n) AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) digits(n)),
 Slots(n) AS (SELECT @offset+a.n+10*b.n+100*c.n FROM D a CROSS JOIN D b CROSS JOIN D c WHERE a.n+10*b.n+100*c.n<@size AND @offset+a.n+10*b.n+100*c.n<@total)
 SELECT t.target,sample.SampleTime,sample.QualityCode,` + columns(points) + `
 FROM dbo.Station s CROSS JOIN Slots CROSS APPLY (SELECT DATEADD(minute,Slots.n*@interval,CONVERT(datetime2(3),@from)) AS target) t
 OUTER APPLY (SELECT TOP (1) h.* FROM dbo.StationSample h WHERE h.StationId=s.StationId
 AND h.SampleTime>=@from AND h.SampleTime<@to AND h.SampleTime BETWEEN DATEADD(second,-30*@interval,t.target) AND DATEADD(second,30*@interval,t.target)
 ORDER BY ABS(DATEDIFF_BIG(millisecond,t.target,h.SampleTime)),h.SampleTime) sample
 WHERE s.StationCode=@station AND s.IsEnabled=1 ORDER BY Slots.n`
}

func queryAlarms(ctx context.Context, db *sql.DB, in Request, from, to time.Time) ([]map[string]*string, bool, error) {
	const query = `SELECT CONVERT(varchar(23),EventTime,121),CONVERT(varchar(23),AlarmTime,121),GroupName,TagName,TagComment,AlarmText,AlarmType,EventType,Pri,AlarmValue,LimitValue,ResumeValue,OperatorName
 FROM dbo.Alarm WHERE EventTime>=@from AND EventTime<@to
 AND (@event=N'' OR EventType=@event) AND (@tag=N'' OR CHARINDEX(@tag,TagName)>0)
 ORDER BY EventTime DESC,EventTimeMs DESC,TagName,AlarmTime,EventType,IOServerName,GroupName,TagComment,AlarmText,AlarmType,Pri,AlarmValue,LimitValue,ResumeValue,OperatorName
 OFFSET @offset ROWS FETCH NEXT 501 ROWS ONLY`
	rows, e := db.QueryContext(ctx, query, sql.Named("from", from), sql.Named("to", to), sql.Named("event", in.EventType), sql.Named("tag", in.Tag), sql.Named("offset", in.Offset))
	if e != nil {
		return nil, false, queryError(ctx)
	}
	defer rows.Close()
	keys := []string{"event_time", "alarm_time", "group", "tag", "comment", "description", "alarm_type", "event_type", "priority", "alarm_value", "limit_value", "resume_value", "operator"}
	out := make([]map[string]*string, 0)
	for rows.Next() {
		if len(out) == 500 {
			return out, true, nil
		}
		fields := make([]*string, len(keys))
		dest := make([]any, len(keys))
		for i := range fields {
			dest[i] = &fields[i]
		}
		if e := rows.Scan(dest...); e != nil {
			return nil, false, queryError(ctx)
		}
		event := make(map[string]*string, len(keys))
		for i, key := range keys {
			event[key] = fields[i]
		}
		out = append(out, event)
	}
	if rows.Err() != nil {
		return nil, false, queryError(ctx)
	}
	return out, false, nil
}

func rangeTime(raw string, zone *time.Location) (time.Time, error) {
	for _, layout := range []string{"2006-01-02T15:04", "2006-01-02T15:04:05"} {
		if t, e := time.ParseInLocation(layout, raw, zone); e == nil && t.Format(layout) == raw {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("请选择有效日期时间")
}
