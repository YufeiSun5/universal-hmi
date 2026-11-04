package externaldata

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

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
	more := false
	for rows.Next() {
		if len(out) == 500 {
			more = true
			break
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
	if e := rows.Close(); e != nil {
		return nil, false, queryError(ctx)
	}
	if e := matchAlarmPeople(ctx, db, out); e != nil {
		if ctx.Err() != nil {
			return nil, false, queryError(ctx)
		}
		return nil, false, fmt.Errorf("报警确认人查询失败，请检查 OperationLog 和 TerminalSession 表及读取权限")
	}
	return out, more, nil
}

func rangeTime(raw string, zone *time.Location) (time.Time, error) {
	for _, layout := range []string{"2006-01-02T15:04", "2006-01-02T15:04:05"} {
		if t, e := time.ParseInLocation(layout, raw, zone); e == nil && t.Format(layout) == raw {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("请选择有效日期时间")
}
