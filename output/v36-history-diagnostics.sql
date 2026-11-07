-- v36 实际查询与诊断；只读取，不修改数据或配置。
-- 请使用与平台相同的数据库及数据库账号执行。
USE [KIOHistory];
GO
SELECT DB_NAME() AS 当前数据库, ORIGINAL_LOGIN() AS 当前登录;

-- 1. 能耗当前总览：与平台相同的过程及参数。
DECLARE @asof datetime2(3) = SYSUTCDATETIME();
DECLARE @reportDate date = CONVERT(date, DATEADD(hour, 8, @asof));
SELECT @reportDate AS 报表日期北京, @asof AS 查询时刻UTC;
EXEC dbo.usp_查询站区当前统计
    @站区编码 = NULL,
    @整站编码 = NULL,
    @按整站 = 1,
    @报表日期 = @reportDate,
    @逐小时 = 0,
    @查询时刻UTC = @asof;

-- 2. 仅中心站：能耗按整站01-001，不用分区01-001-01。
EXEC dbo.usp_查询站区当前统计
    @站区编码 = NULL,
    @整站编码 = '01-001',
    @按整站 = 1,
    @报表日期 = @reportDate,
    @逐小时 = 0,
    @查询时刻UTC = @asof;
GO

-- 3. 东南区最新原始读数：诊断查询，不受Point映射过滤。
SELECT TOP (10)
    s.StationCode, s.StationName,
    DATEADD(hour, 8, h.SampleTime) AS 采样时间北京,
    h.Value06 AS 一次网累计热量_GJ,
    h.Value31 AS 二次网累计热量_GJ,
    h.QualityCode
FROM dbo.Station s
JOIN dbo.StationSample h ON h.StationId = s.StationId
WHERE s.StationCode = '01-001-01' AND s.IsEnabled = 1
ORDER BY h.SampleTime DESC;

-- 4. 全部Point定义及平台加载条件；保留被排除的定义以便查原因。
SELECT s.StationCode, s.StationName, s.IsEnabled AS StationEnabled,
    p.PointCode, p.PointName, p.Unit, p.DeviceId,
    p.SampleTable, p.SampleColumn, p.ValueType, p.IsEnabled AS PointEnabled,
    CASE WHEN s.IsEnabled = 1 AND p.IsEnabled = 1
              AND p.DeviceId IS NULL AND p.SampleTable = 'StationSample'
         THEN N'满足平台测点加载WHERE条件'
         ELSE N'被平台测点加载WHERE条件排除' END AS 平台加载检查
FROM dbo.Point p
JOIN dbo.Station s ON s.StationId = p.StationId
WHERE s.StationCode = '01-001-01'
ORDER BY p.SampleColumn, p.PointCode;

-- 5. 平台实际使用的测点定义SQL；后端还校验Value01..60和类型N/B/E及唯一性。
DECLARE @station varchar(32) = '01-001-01';
SELECT TOP (61) p.PointCode,p.PointName,COALESCE(p.Unit,''),p.SampleColumn,p.ValueType
FROM dbo.Point p JOIN dbo.Station s ON s.StationId=p.StationId
WHERE s.StationCode=@station AND s.IsEnabled=1 AND p.IsEnabled=1
  AND p.DeviceId IS NULL AND p.SampleTable='StationSample'
ORDER BY p.PointCode;
GO

-- 6. 普通历史：同平台目标时间/最近采样SQL。
-- 这里为便于排查直接选择Value06/Value31；平台实际列来自上面Point查询。
-- 使用此前已知样本的北京时间2026-11-04 11:11至11:12、1分钟间隔。
-- 平台把界面时间转换成UTC后绑定；结束时间不包含在范围内。
DECLARE @station varchar(32)='01-001-01';
DECLARE @from datetime2(3)='2026-11-04T03:11:00';
DECLARE @to datetime2(3)='2026-11-04T03:12:00';
DECLARE @interval int=1, @offset int=0, @size int=500, @total int=1;
WITH D(n) AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) digits(n)),
Slots(n) AS (
    SELECT @offset+a.n+10*b.n+100*c.n
    FROM D a CROSS JOIN D b CROSS JOIN D c
    WHERE a.n+10*b.n+100*c.n<@size
      AND @offset+a.n+10*b.n+100*c.n<@total
)
SELECT t.target AS 目标时间UTC, sample.SampleTime AS 实际采样UTC,
       sample.QualityCode,
       CONVERT(varchar(64),sample.[Value06]) AS 一次网累计热量_GJ,
       CONVERT(varchar(64),sample.[Value31]) AS 二次网累计热量_GJ
FROM dbo.Station s CROSS JOIN Slots
CROSS APPLY (SELECT DATEADD(minute,Slots.n*@interval,CONVERT(datetime2(3),@from)) AS target) t
OUTER APPLY (
    SELECT TOP (1) h.* FROM dbo.StationSample h WHERE h.StationId=s.StationId
      AND h.SampleTime>=@from AND h.SampleTime<@to
      AND h.SampleTime BETWEEN DATEADD(second,-30*@interval,t.target)
                           AND DATEADD(second,30*@interval,t.target)
    ORDER BY ABS(DATEDIFF_BIG(millisecond,t.target,h.SampleTime)),h.SampleTime
) sample
WHERE s.StationCode=@station AND s.IsEnabled=1 ORDER BY Slots.n;
-- 平台对质量1/2保留非空原始值；其他质量在响应中置空。
-- 能耗结果后处理：指标只识别耗电量/补水量/一次网耗热量或对应ER_*代码。
-- 今日状态仅“截至采样有效”保留日值；小时状态仅“有效/有效含异常/截至采样有效”保留小时值。
