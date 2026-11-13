-- 小时/日统计核对。连接KIOHistory后，各编号可单独选中执行。
-- 无GO，不创建或修改表，不调用安装、重算或刷新过程。
-- 1：已有整站小时查询过程，查询今天。
EXEC KIOHistory.dbo.usp_整站消耗查询 @粒度=N'小时';

-- 2：已有整站日查询过程，查询今天。
EXEC KIOHistory.dbo.usp_整站消耗查询 @粒度=N'日';
-- 若提示找不到过程，说明现场未部署这个入口；保留错误，继续下面的直接查表。


-- 3：直接读今天日表的水电热，不经过整站成员配置。
-- 按PointCode和统计输出列映射，不假定每个站都用Value06/20/27。
-- 日表的有效小计与完整日用量分列；今天未结束时完整日用量可以为空。
SELECT s.StationCode AS 站区编码,s.StationName AS 站区名称,k.指标,
       p.Unit AS 单位,w.输出列 AS 统计输出列,
       t.统计时间,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'Delta"') AS 完整日用量,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'Subtotal"') AS 有效小时用量小计,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'Hours"') AS 有效小时数,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'Status"') AS 状态码,
       q.说明 AS 状态说明,
       CASE WHEN p.PointId IS NULL THEN N'缺测点定义'
            WHEN w.PointId IS NULL THEN N'缺统计列配置'
            WHEN t.统计时间 IS NULL THEN N'今天无日表记录'
            ELSE N'已读取存储值，请结合状态核对' END AS 读取情况
FROM KIOHistory.dbo.Station s
CROSS JOIN (VALUES
    ('ER_MakeupFlowTotal',N'补水'),
    ('ER_ActiveEnergyTotal',N'耗电'),
    ('ER_TotalHeat',N'一次网耗热')
) k(指标编码,指标)
LEFT JOIN KIOHistory.dbo.Point p ON p.StationId=s.StationId AND p.PointCode=k.指标编码
LEFT JOIN KIOHistory.dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
OUTER APPLY (
    SELECT TOP (1) x.*
    FROM KIOHistory.dbo.日表 x
    WHERE x.StationId=s.StationId
      AND x.统计时间>=CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME()))
      AND x.统计时间<DATEADD(day,1,CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME())))
    ORDER BY x.统计时间 DESC
) t
CROSS APPLY (SELECT (SELECT t.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) AS payload) j
LEFT JOIN KIOHistory.dbo.v_统计状态规则 q
    ON q.状态码=TRY_CONVERT(int,JSON_VALUE(j.payload,N'$."'+w.输出列+N'Status"'))
WHERE s.IsEnabled=1
ORDER BY s.StationCode,k.指标编码;


-- 4：直接读今天各站区最新一条小时表的水电热，不经过整站成员配置。
-- 按PointCode和统计输出列映射，不假定每个站都用Value06/20/27。
-- 这里只核对最新已落库小时，不代表今天每个小时都完整。
SELECT s.StationCode AS 站区编码,s.StationName AS 站区名称,k.指标,
       p.Unit AS 单位,w.输出列 AS 统计输出列,
       t.统计时间,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'Delta"') AS 小时用量,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'FirstUTC"') AS 起点采样UTC,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'LastUTC"') AS 终点采样UTC,
       JSON_VALUE(j.payload,N'$."'+w.输出列+N'Status"') AS 状态码,
       q.说明 AS 状态说明,
       CASE WHEN p.PointId IS NULL THEN N'缺测点定义'
            WHEN w.PointId IS NULL THEN N'缺统计列配置'
            WHEN t.统计时间 IS NULL THEN N'今天无小时表记录'
            ELSE N'已读取存储值，请结合状态核对' END AS 读取情况
FROM KIOHistory.dbo.Station s
CROSS JOIN (VALUES
    ('ER_MakeupFlowTotal',N'补水'),
    ('ER_ActiveEnergyTotal',N'耗电'),
    ('ER_TotalHeat',N'一次网耗热')
) k(指标编码,指标)
LEFT JOIN KIOHistory.dbo.Point p ON p.StationId=s.StationId AND p.PointCode=k.指标编码
LEFT JOIN KIOHistory.dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
OUTER APPLY (
    SELECT TOP (1) x.*
    FROM KIOHistory.dbo.小时表 x
    WHERE x.StationId=s.StationId
      AND x.统计时间>=CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME()))
      AND x.统计时间<DATEADD(day,1,CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME())))
    ORDER BY x.统计时间 DESC
) t
CROSS APPLY (SELECT (SELECT t.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) AS payload) j
LEFT JOIN KIOHistory.dbo.v_统计状态规则 q
    ON q.状态码=TRY_CONVERT(int,JSON_VALUE(j.payload,N'$."'+w.输出列+N'Status"'))
WHERE s.IsEnabled=1
ORDER BY s.StationCode,k.指标编码;
