-- Match against the login-time identity snapshot. Only this alarm page's
-- confirmation rows enter the query. RequestedAt and eventUTC are UTC.
WITH Confirmations AS (
    SELECT * FROM OPENJSON(@events) WITH (
        rowNo int '$.Row', org nvarchar(max) '$.Organization', eventUTC datetime2(3) '$.UTC'
    )
), SessionEvents AS (
    SELECT h.OperationId, h.RequestedAt, h.ActionCode, j.*
    FROM dbo.OperationLog h
    CROSS APPLY OPENJSON(CASE WHEN ISJSON(h.DetailJson)=1 THEN h.DetailJson END)
    WITH (userId varchar(20) '$.user_id', username nvarchar(100) '$.username',
          org nvarchar(128) '$.organization', terminal bigint '$.terminal',
          sessionKey varchar(128) '$.session_key', ns varchar(20) '$.terminal_namespace') j
    WHERE h.RecordKind=1 AND h.SourceSystem='usersession' AND h.EventKey='result'
      AND h.Outcome='succeeded' AND h.ActionCode IN ('login','logout') AND j.ns='ip'
)
SELECT c.rowNo, CASE WHEN EXISTS (
    SELECT 1 FROM SessionEvents b
    WHERE CONVERT(varbinary(max),b.org)=CONVERT(varbinary(max),c.org)
      AND b.RequestedAt>clock.secondStart AND b.RequestedAt<DATEADD(second,1,clock.secondStart)
) THEN N'换班边界，无法确定'
WHEN persons.n=1 THEN persons.personName WHEN persons.n>1 THEN N'多人匹配' ELSE N'未记录' END
FROM Confirmations c
CROSS APPLY (SELECT DATEADD(millisecond,-DATEPART(millisecond,c.eventUTC),c.eventUTC) AS secondStart) clock
CROSS APPLY (
    SELECT COUNT(DISTINCT h.userId) AS n, MAX(h.username) AS personName
    FROM SessionEvents h
    LEFT JOIN dbo.OperationLog e ON e.RecordKind=1 AND e.SourceSystem='usersession'
      AND e.SourceOperationKey=h.sessionKey+'/logout' AND e.EventKey='result'
      AND e.ActionCode='logout' AND e.Outcome='succeeded'
    WHERE h.ActionCode='login' AND h.userId IS NOT NULL AND h.username IS NOT NULL
      AND CONVERT(varbinary(max),h.org)=CONVERT(varbinary(max),c.org)
      AND h.RequestedAt<=c.eventUTC AND (e.RequestedAt>c.eventUTC OR (
          e.OperationId IS NULL AND c.eventUTC<=SYSUTCDATETIME() AND EXISTS (
              SELECT 1 FROM dbo.TerminalSession t
              WHERE t.IP=h.terminal AND t.CurrentUserId=TRY_CONVERT(int,h.userId)
                AND h.sessionKey='ip/'+CONVERT(varchar(20),t.IP)+'/'+CONVERT(varchar(20),t.StateVersion)
          )
      ))
) persons
