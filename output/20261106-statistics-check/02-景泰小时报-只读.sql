-- 在现场平台所连接的 KIOHistory，使用相同查询账号，全文执行。
-- 仅读取现有接口、字典、来源版本和采样；临时表仅存在于当前连接。
-- 固定复查截图中的景泰高区、2026-11-05；不安装、不补算、不修改业务表。
USE [KIOHistory];
SET NOCOUNT ON;
DECLARE @zone varchar(32)='01-002-01';
DECLARE @day date='20261105';
DECLARE @asof datetime2(3)=SYSUTCDATETIME();
DECLARE @endUTC datetime2(3)=DATEADD(hour,-8,CONVERT(datetime2(3),DATEADD(day,1,@day)));

SELECT DB_NAME() 数据库,CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')) 服务器,
       ORIGINAL_LOGIN() 查询账号,@zone 站区,@day 报表日期北京;

DROP TABLE IF EXISTS #JingtaiHourlyCheck;
CREATE TABLE #JingtaiHourlyCheck(
  站区编码 varchar(32),站区名称 nvarchar(200),输出列 nvarchar(128),测点 nvarchar(200),单位 nvarchar(50),
  当前小时起点 datetime2(3),最新参与采样时间 datetime2(3),
  当前小时差额 decimal(38,8),当前小时最小值 decimal(38,8),当前小时最大值 decimal(38,8),
  当前小时状态 nvarchar(200),今日有效差额小计 decimal(38,8),
  今日最小值 decimal(38,8),今日最大值 decimal(38,8),今日状态 nvarchar(200)
);
INSERT #JingtaiHourlyCheck
EXEC dbo.usp_查询站区当前统计 @站区编码=@zone,@整站编码=NULL,@按整站=0,
    @报表日期=@day,@逐小时=1,@查询时刻UTC=@asof;

-- 结果2：截图末尾五个测点的小时值及数据库给出的缺值原因。
-- 通过 Point -> 统计输出列映射筛选，不假定原始列等于统计列。
SELECT N'2_小时值和状态' 结果组,h.*
FROM #JingtaiHourlyCheck h
WHERE EXISTS (
    SELECT 1 FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId
    JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
    WHERE s.StationCode=@zone AND w.输出列=h.输出列
      AND p.SampleColumn IN('Value28','Value29','Value30','Value31','Value32')
)
ORDER BY h.输出列,h.当前小时起点;

-- 结果3：原始字段、统计字段和当天结束前最后一个来源版本。
-- 仅展示版本，不把最后版本当成当天所有小时均使用的版本。
SELECT N'3_字段及来源版本' 结果组,s.StationCode,s.StationName,p.PointCode,p.PointName,
       p.SampleColumn 原始列,w.输出列 统计列,p.Unit,
       DATEADD(hour,8,m.生效UTC) 来源生效北京,m.来源列,m.算差额,m.来源状态
FROM dbo.Station s JOIN dbo.Point p ON p.StationId=s.StationId
LEFT JOIN dbo.统计宽表列配置 w ON w.StationId=s.StationId AND w.PointId=p.PointId
OUTER APPLY (
    SELECT TOP(1) x.* FROM dbo.统计测点来源 x
    WHERE x.PointId=p.PointId AND x.生效UTC<@endUTC ORDER BY x.生效UTC DESC
) m
WHERE s.StationCode=@zone AND p.SampleColumn IN('Value28','Value29','Value30','Value31','Value32')
ORDER BY p.SampleColumn;

-- 结果4：当天最后三条原始读数。累计表底只作对照，不能当小时用量。
SELECT TOP(3) N'4_原始读数' 结果组,DATEADD(hour,8,r.SampleTime) 采样北京,r.QualityCode,
       r.Value28 室外温度,r.Value29 循环泵3电流,r.Value30 循环泵3频率,
       r.Value31 二次网累计热量,r.Value32 二次网累计流量
FROM dbo.Station s JOIN dbo.StationSample r ON r.StationId=s.StationId
WHERE s.StationCode=@zone AND r.SampleTime>=DATEADD(day,-1,@endUTC) AND r.SampleTime<@endUTC
ORDER BY r.SampleTime DESC;
DROP TABLE #JingtaiHourlyCheck;
