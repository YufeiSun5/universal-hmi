-- 全站区水、电、热完整性核查。
-- 连接平台使用的同一数据库服务器，将全文作为一个批次执行。
-- 脚本只读取字典、配置，并调用现有查询过程；不自行创建表或修改数据。
USE [KIOHistory];
SET NOCOUNT ON;

DECLARE @核查时刻UTC datetime2(3) = SYSUTCDATETIME();
DECLARE @核查日期 date = CONVERT(date, DATEADD(hour, 8, @核查时刻UTC));
-- 核查过去某天时，只把上面@核查日期的赋值改成日期，例如 '2026-11-03'。

-- 结果1：本次核查范围。启用站区总数用于检查后续结果是否漏站。
SELECT N'1_核查范围' AS 结果组,
       CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')) AS 服务器,
       DB_NAME() AS 数据库,
       @核查日期 AS 核查日期北京,
       DATEADD(hour, 8, @核查时刻UTC) AS 核查时刻北京,
       (SELECT COUNT(*) FROM dbo.Station WHERE IsEnabled = 1) AS 启用站区数;

-- 结果2：每个启用站区都列出水、电、热三项，包括缺少定义或统计列的项。
-- 后续用“站区编码 + 统计输出列”对应结果3，不靠中文测点名称猜测。
-- 本组仅核查取数配置；“有配置”不等于数据完整。
SELECT N'2_水电热测点清单' AS 结果组,
       s.StationCode AS 站区编码, s.StationName AS 站区名称,
       k.指标, k.指标编码, p.PointName AS 测点名称, p.Unit AS 单位,
       p.IsEnabled AS 测点启用, w.输出列 AS 统计输出列,
       m.来源列, m.来源状态, m.算差额, m.生效UTC AS 来源生效UTC,
       CASE WHEN p.PointId IS NULL THEN N'缺测点定义'
            WHEN w.PointId IS NULL THEN N'缺统计列配置'
            WHEN m.生效UTC IS NULL THEN N'截至核查时刻无来源配置'
            ELSE N'有配置，继续核对结果3的数值和状态' END AS 配置检查
FROM dbo.Station s
CROSS JOIN (VALUES
    ('ER_MakeupFlowTotal', N'补水'),
    ('ER_ActiveEnergyTotal', N'耗电'),
    ('ER_TotalHeat', N'一次网耗热')
) k(指标编码, 指标)
LEFT JOIN dbo.Point p ON p.StationId = s.StationId AND p.PointCode = k.指标编码
LEFT JOIN dbo.统计宽表列配置 w ON w.StationId = s.StationId AND w.PointId = p.PointId
OUTER APPLY (
    SELECT TOP (1) 来源列, 来源状态, 算差额, 生效UTC
    FROM dbo.统计测点来源
    WHERE PointId = p.PointId AND 生效UTC <= @核查时刻UTC
    ORDER BY 生效UTC DESC
) m
WHERE s.IsEnabled = 1
ORDER BY s.StationCode, k.指标编码;

-- 结果3：所有已配置统计的站区，原样返回用量、状态和最新参与采样时间。
-- 此处采用站区查询，不依赖整站成员规则；也会返回温度等其他工况指标。
-- 结果2中的缺配置项可能不出现在结果3，不能忽略这些站区后宣称数据齐全。
EXEC dbo.usp_查询站区当前统计
    @站区编码 = NULL,
    @整站编码 = NULL,
    @按整站 = 0,
    @报表日期 = @核查日期,
    @逐小时 = 0,
    @查询时刻UTC = @核查时刻UTC;

-- 判断方法：
-- 1. 结果2列出的各站区三项都应能在结果3按统计输出列找到。
-- 2. 水电热的“当前小时差额”应为非NULL，小时状态为“有效”或“有效含异常”。
-- 3. “今日有效差额小计”应为非NULL，今日状态为“截至采样有效”。
-- 4. 0是有效数值；NULL不是0。保留“有效含异常”等标记继续核查。
-- 5. 检查最新参与采样时间，不能把旧数据当作当前持续采集的证据。
-- 今天通过这些检查，只能证明截至采样时刻的数据；不能证明今天剩余时间或其他日期完整。
-- 过去日期的来源配置历史仍以过程返回的统计状态为准，结果2显示截至核查时刻的配置。
