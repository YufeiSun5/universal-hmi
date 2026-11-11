-- 在平台相同数据库和查询账号下全文执行。不修改业务数据、配置或统计结果。
-- 只查中心站两区和国奥二期两区，定位今日缺失小时与日状态。
USE [KIOHistory];
SET NOCOUNT ON;
DECLARE @asof datetime2(3)=SYSUTCDATETIME();
DECLARE @day date=CONVERT(date,DATEADD(hour,8,@asof));
DECLARE @zones varchar(max)='01-001-01,01-001-02,02-005-01,02-005-02';

SELECT N'1_查询环境' 结果组,CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')) 服务器,
 DB_NAME() 数据库,ORIGINAL_LOGIN() 查询账号,@day 报表日期北京,DATEADD(hour,8,@asof) 查询时间北京;

DROP TABLE IF EXISTS #TodayUsageCheck;
CREATE TABLE #TodayUsageCheck(
  站区编码 varchar(32),站区名称 nvarchar(200),输出列 nvarchar(128),测点 nvarchar(200),单位 nvarchar(50),
  当前小时起点 datetime2(3),最新参与采样时间 datetime2(3),
  当前小时差额 decimal(38,8),当前小时最小值 decimal(38,8),当前小时最大值 decimal(38,8),
  当前小时状态 nvarchar(200),今日有效差额小计 decimal(38,8),
  今日最小值 decimal(38,8),今日最大值 decimal(38,8),今日状态 nvarchar(200)
);
INSERT #TodayUsageCheck
EXEC dbo.usp_查询站区当前统计 @站区编码=@zones,@整站编码=NULL,@按整站=0,
 @报表日期=@day,@逐小时=1,@查询时刻UTC=@asof;

-- 一行一个站区水电热测点。小计仅用于诊断，不能冒充完整当日用量。
;WITH energy AS (
 SELECT h.*,p.PointCode FROM #TodayUsageCheck h
 JOIN dbo.Station s ON s.StationCode=h.站区编码
 JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.输出列=h.输出列
 JOIN dbo.Point p ON p.PointId=w.PointId AND p.StationId=s.StationId
 WHERE p.PointCode IN('ER_TotalHeat','ER_MakeupFlowTotal','ER_ActiveEnergyTotal')
)
SELECT N'2_日状态及异常小时数' 结果组,站区编码,站区名称,PointCode,测点,单位,
 MAX(今日状态) 今日状态,MAX(今日有效差额小计) 数据库返回的小计,
 COUNT(*) 返回小时数,
 SUM(CASE WHEN 当前小时状态 IN(N'有效',N'有效含异常') AND 当前小时差额 IS NOT NULL THEN 1 ELSE 0 END) 有效小时数,
 MIN(CASE WHEN 当前小时状态 IS NULL OR 当前小时状态 NOT IN(N'有效',N'有效含异常') OR 当前小时差额 IS NULL THEN 当前小时起点 END) 首个异常小时北京
FROM energy GROUP BY 站区编码,站区名称,PointCode,测点,单位 ORDER BY 站区编码,PointCode;

-- 逐小时原样返回，便于看清早期缺数与当前有值的边界，不在软件重新求和。
SELECT N'3_逐小时原始状态' 结果组,h.站区编码,h.站区名称,p.PointCode,h.测点,h.单位,
 h.当前小时起点,h.当前小时差额,h.当前小时状态,h.最新参与采样时间,h.今日状态
FROM #TodayUsageCheck h
JOIN dbo.Station s ON s.StationCode=h.站区编码
JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.输出列=h.输出列
JOIN dbo.Point p ON p.PointId=w.PointId AND p.StationId=s.StationId
WHERE p.PointCode IN('ER_TotalHeat','ER_MakeupFlowTotal','ER_ActiveEnergyTotal')
ORDER BY h.站区编码,p.PointCode,h.当前小时起点;

-- 实际已落库的小时标签；不能用当前小时能查到值推断早期小时已结算。
SELECT N'4_今日小时表落库概况' 结果组,s.StationCode,s.StationName,
 COUNT(h.统计时间) 已存小时行数,MIN(h.统计时间) 首个已存小时,MAX(h.统计时间) 最后已存小时
FROM dbo.Station s LEFT JOIN dbo.小时表 h ON h.StationId=s.StationId
 AND h.统计时间>=@day AND h.统计时间<DATEADD(day,1,@day)
WHERE s.StationCode IN('01-001-01','01-001-02','02-005-01','02-005-02')
GROUP BY s.StationCode,s.StationName ORDER BY s.StationCode;
DROP TABLE #TodayUsageCheck;
