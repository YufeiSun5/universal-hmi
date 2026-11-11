-- 能耗页面“有数值却显示 —”只读核查。
-- 使用平台配置的同一服务器、数据库和查询账号，将全文作为一条SQL/一个批次执行。
-- 包含共享局部变量，请勿逐句执行；兼容不识别客户端批次分隔符的查询工具。
-- 脚本仅调用现有查询过程和读取规则，不自行创建表或写入数据。
USE [KIOHistory];
SET NOCOUNT ON;

-- 默认查询今天、全部整站，与页面“全部整站 / 当前总览”一致。
DECLARE @查询时刻UTC datetime2(3) = SYSUTCDATETIME();
DECLARE @报表日期 date = CONVERT(date, DATEADD(hour, 8, @查询时刻UTC));
DECLARE @整站编码 varchar(32) = NULL;
-- 若需固定复查截图时刻，可将上面时间改为 '2026-11-06T01:14:45'（北京09:14:45）。
-- 固定时刻只供复查截图；排查当前情况时使用默认当前UTC并与刚刷新页面对照。

-- 结果1：确认连接和查询时间。这里不读取密码或连接串。
SELECT N'1_连接及查询时间' AS 结果组,
       CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')) AS 数据库服务器,
       DB_NAME() AS 数据库, ORIGINAL_LOGIN() AS 查询账号,
       @报表日期 AS 报表日期北京,
       @查询时刻UTC AS 查询时刻UTC,
       DATEADD(hour, 8, @查询时刻UTC) AS 查询时刻北京;

-- 结果2：原样返回数据库的用量与状态，不过滤、不接收进临时表。
EXEC dbo.usp_查询站区当前统计
    @站区编码 = NULL,
    @整站编码 = @整站编码,
    @按整站 = 1,
    @报表日期 = @报表日期,
    @逐小时 = 0,
    @查询时刻UTC = @查询时刻UTC;

-- 结果3：当日适用的整站成员规则。只读取，不自动创建规则或汇总站区。
;WITH sites AS (
    SELECT DISTINCT LEFT(StationCode, 6) AS 整站编码
    FROM dbo.Station
    WHERE IsEnabled = 1
      AND (@整站编码 IS NULL OR LEFT(StationCode, 6) = @整站编码)
)
SELECT N'3_整站计量规则' AS 结果组, s.整站编码, k.指标,
       r.生效日期, r.成员站区,
       CASE WHEN r.生效日期 IS NULL THEN N'该日期没有适用规则'
            ELSE N'有规则，请结合结果2的状态核对成员' END AS 规则检查
FROM sites s
CROSS JOIN (VALUES
    ('ER_MakeupFlowTotal', N'补水量'),
    ('ER_ActiveEnergyTotal', N'耗电量'),
    ('ER_TotalHeat', N'一次网耗热量')
) k(指标编码, 指标)
OUTER APPLY (
    SELECT TOP (1) 生效日期, 成员站区
    FROM dbo.整站能耗口径
    WHERE 整站编码 = s.整站编码 AND 指标编码 = k.指标编码
      AND 生效日期 <= @报表日期
    ORDER BY 生效日期 DESC
) r
ORDER BY s.整站编码, k.指标;

-- 请保留结果2的原始数值、指标名称、当前小时状态和今日状态，以便核对平台过滤。
