-- v36 后端实际查询的可独立执行版本，SQL Server 2019。
-- 在 SSMS 中连接与软件相同的服务器，尽量使用软件配置的数据库账号。
-- 不创建或修改数据库对象。各段可单独选中执行。
USE [KIOHistory];
GO

-- 1. 软件加载的启用站区。用实际 StationCode 替换后续示例编码。
SELECT TOP (257) StationCode, StationName
FROM dbo.Station
WHERE IsEnabled = 1
ORDER BY StationCode;
GO

-- 2. 普通历史：测点映射。查询无结果时，软件不会继续加载采样值。
DECLARE @station nvarchar(32) = N'01-001-01';
SELECT TOP (61)
    p.PointCode, p.PointName, COALESCE(p.Unit, '') AS Unit,
    p.SampleColumn, p.ValueType
FROM dbo.Point p
JOIN dbo.Station s ON s.StationId = p.StationId
WHERE s.StationCode = @station AND s.IsEnabled = 1
  AND p.IsEnabled = 1 AND p.DeviceId IS NULL
  AND p.SampleTable = 'StationSample'
ORDER BY p.PointCode;
GO

-- 3. 普通历史：按分钟间隔取最近采样，与 reports.go 的查询逻辑一致。
-- 以下输入是软件界面显示的本地时间；按数据源时区转 UTC 后查询。
-- +480 为北京时间。若软件数据源另有时区配置，请同步修改。
-- SampleTime 按现有后端约定使用 UTC；结束时间不包含在范围中。
DECLARE @station nvarchar(32) = N'01-001-01';
DECLARE @localFrom datetime2(3) = '2026-11-04T08:00:00';
DECLARE @localTo datetime2(3) = '2026-11-04T12:00:00';
DECLARE @utcOffsetMinutes int = 480;
DECLARE @interval int = 5; -- 分钟
DECLARE @offset int = 0;   -- 第一页；第二页为500
DECLARE @size int = 500;
DECLARE @from datetime2(3) = DATEADD(minute, -@utcOffsetMinutes, @localFrom);
DECLARE @to datetime2(3) = DATEADD(minute, -@utcOffsetMinutes, @localTo);
DECLARE @total int = CONVERT(int,
    (DATEDIFF_BIG(millisecond, @from, @to) + CONVERT(bigint, @interval)*60000 - 1)
    / (CONVERT(bigint, @interval)*60000));
DECLARE @columns nvarchar(max);

-- 后端使用相同映射生成 Value01..Value60 投影；此脚本补充列别名便于阅读。
SELECT @columns = STRING_AGG(
    CAST(N'CONVERT(varchar(64),sample.' + QUOTENAME(p.SampleColumn)
         + N') AS ' + QUOTENAME(p.SampleColumn) AS nvarchar(max)), N',')
    WITHIN GROUP (ORDER BY p.SampleColumn)
FROM dbo.Point p
JOIN dbo.Station s ON s.StationId = p.StationId
WHERE s.StationCode = @station AND s.IsEnabled = 1
  AND p.IsEnabled = 1 AND p.DeviceId IS NULL
  AND p.SampleTable = 'StationSample'
  AND p.SampleColumn COLLATE Latin1_General_100_BIN2 LIKE 'Value[0-9][0-9]'
  AND TRY_CONVERT(int, RIGHT(p.SampleColumn, 2)) BETWEEN 1 AND 60;

IF @columns IS NULL
BEGIN
    ;THROW 50001, N'没有有效测点映射，请先检查第2段结果。', 1;
END;

DECLARE @sql nvarchar(max) = N'
WITH D(n) AS (
    SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) digits(n)
), Slots(n) AS (
    SELECT @offset+a.n+10*b.n+100*c.n
    FROM D a CROSS JOIN D b CROSS JOIN D c
    WHERE a.n+10*b.n+100*c.n<@size
      AND @offset+a.n+10*b.n+100*c.n<@total
)
SELECT t.target AS TargetTimeUTC, sample.SampleTime AS SampleTimeUTC,
       sample.QualityCode,' + @columns + N'
FROM dbo.Station s
CROSS JOIN Slots
CROSS APPLY (
    SELECT DATEADD(minute,Slots.n*@interval,CONVERT(datetime2(3),@from)) AS target
) t
OUTER APPLY (
    SELECT TOP (1) h.*
    FROM dbo.StationSample h
    WHERE h.StationId=s.StationId
      AND h.SampleTime>=@from AND h.SampleTime<@to
      AND h.SampleTime BETWEEN DATEADD(second,-30*@interval,t.target)
                           AND DATEADD(second,30*@interval,t.target)
    ORDER BY ABS(DATEDIFF_BIG(millisecond,t.target,h.SampleTime)),h.SampleTime
) sample
WHERE s.StationCode=@station AND s.IsEnabled=1
ORDER BY Slots.n';

EXEC sys.sp_executesql @sql,
    N'@station nvarchar(32), @from datetime2(3), @to datetime2(3), @interval int, @offset int, @size int, @total int',
    @station=@station, @from=@from, @to=@to, @interval=@interval,
    @offset=@offset, @size=@size, @total=@total;
GO

-- 4. 小时报：单站区、逐小时。日期是北京时间自然日，不减8小时。
DECLARE @nowUTC datetime2(7) = SYSUTCDATETIME();
EXEC dbo.usp_查询站区当前统计
    @站区编码 = N'01-001-01',
    @整站编码 = NULL,
    @按整站 = 0,
    @报表日期 = '2026-11-04',
    @逐小时 = 1,
    @查询时刻UTC = @nowUTC;
GO

-- 5. 日报：单站区、单日。软件多日查询会逐日调用本过程。
DECLARE @nowUTC datetime2(7) = SYSUTCDATETIME();
EXEC dbo.usp_查询站区当前统计
    @站区编码 = N'01-001-01',
    @整站编码 = NULL,
    @按整站 = 0,
    @报表日期 = '2026-11-03',
    @逐小时 = 0,
    @查询时刻UTC = @nowUTC;
GO

-- 6. 能耗：整站日用量。注意整站01-001与站区01-001-01不同。
-- 全站总览：@整站编码=NULL，@报表日期=当天日期。
-- 单站小时趋势：指定整站编码，@逐小时=1。
DECLARE @nowUTC datetime2(7) = SYSUTCDATETIME();
EXEC dbo.usp_查询站区当前统计
    @站区编码 = NULL,
    @整站编码 = N'01-001',
    @按整站 = 1,
    @报表日期 = '2026-11-03',
    @逐小时 = 0,
    @查询时刻UTC = @nowUTC;
GO

-- v36 接收统计结果后的显示规则（不是本脚本额外过滤）：
-- 小时状态为“有效”“有效含异常”“截至采样有效”才显示小时数值。
-- 今日状态为“截至采样有效”才显示日数值；其他状态保留但用量显示“—”。
-- 整站能耗仅保留指标“耗电量”“补水量”“一次网耗热量”，
-- 同时兼容 ER_ActiveEnergyTotal / ER_MakeupFlowTotal / ER_TotalHeat。
-- 若SQL有数据而软件没有，请提供原始列名、状态列和指标列一起核对。
