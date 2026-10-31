# 外数据模块验证（2026-10-27）

产品要求归 [agent.md](../../agent.md)，契约归 [architecture.md](architecture.md)。外数据是工程级独立历史系统；本批实现直接查询外部 SQL Server，首批适配 KIOHistory 结构，未实施任意数据库表设计器。

## 现场参考核对

已只读核对本机 GOKS_restful_API、ZhuangHe16/庄河HTML、数据库设计与 KS_HELP 的现有资料。当前现场文档记载 SQL Server 2019、172.16.1.7、KIOHistory；TCP 端口仍须现场核对。GOKS 根 config.toml 的旧 MySQL 示例不是当前庄河契约。

KingSCADA 每60秒通过 GOKS batch-exec 执行 usp_SaveStationSample60，将28站区采样写入 StationSample；当前 Point 定义把测点映射到 Value01～Value60。HTML 的 report-center 通过 run-sql 调用定义驱动日报过程；其逐日/月/采暖季页签不能据此视为已实现。

本模块 Go 原生 TDS 连接直接读 Station、Point、StationSample，自行实现查询，不依赖 GOKS、ODBC 或现场日报过程，不更改现场采集/入库链路。本批没有连接172.16.1.7，也没有读取或拷贝现场密码。

## 实现和入口

- 开发态最左活动栏“外数据”→“数据源管理”→添加 SQL Server；保存连接不发起网络连接，“测试连接”显式检查连接及表结构。密码留空保留原密文。
- 同一数据源可创建多个逐小时日报、历史明细、历史趋势画面；名称、来源和种类有独立稳定身份。已有画面只能改名，换来源/类型须新建并重新授权。
- 运行态顶部“外数据”显示独立目录。管理员在权限配置中逐个授予外数据画面，全站范围不会自动扩张到外部历史。授权画面允许查询其数据源全部启用站区。
- 单站日报24行；明细/趋势每页500条、最多31天，趋势只画当前页。小数原值以字符串返回；曲线绘制使用浮点近似，精确值看表格。缺测/坏质量显示“—”，真零保留。
- 本机配置保存于既有工程存储；连接密码AES-GCM加密，密钥位于工程external-data/connection.key，恢复工程须同时备份此文件。SQL登录使用只读账号；应用自身只执行固定SELECT，ApplicationIntent不替代数据库权限。

## 验证

新增依赖固定为microsoft/go-mssqldb v1.9.3（BSD，纯Go驱动）、golang-sql/civil（Apache-2.0）、sqlexp v0.1.0（BSD）；go-sqlmock v1.5.2仅用于测试（BSD）。原许可证保存在[licenses/external-data](licenses/external-data)，随本批程序目录交付。

- Go 1.24.7：go test ./...、go vet ./... 通过。新增配置密文/重启、revision冲突、引用删除保护、独立范围、并发上限、参数绑定、列名白名单、精度/质量、分页、查询期间撤权，以及真实身份HTTP/CSRF/origin回归。
- Flutter 3.35.4：analyze通过，全量192项通过；最终增加外数据上下文页签后19项外数据/工作区回归通过。
- Web/Windows release与同源封装通过；源码摘要和部署核对见 [deployment.json](evidence/20261027-external-data/deployment.json)。旧远端CI 38031925060 success（f552d81c）不覆盖当前工作树。
- 实际SQL Server 2019隔离容器，回环18433，独立KIOHistory测试库505条合成采样。只授予SELECT的登录验证24小时、UTC+8、等距取早、decimal(28,8)精度、零/NULL、质量0/2、缺测、500＋1分页及31天限制；尝试无匹配行DELETE仍被权限拒绝。[实际数据库证据](evidence/20261027-external-data/sqlserver-integration.json)。
- 实际Chrome操作：独立活动栏/目录、日报日期查询、趋势与第二页、编辑连接留空保留密码后显式连接检查通过。[日报](evidence/20261027-external-data/daily.png)、[趋势](evidence/20261027-external-data/trend.png)。自动化fill产生两次Flutter引擎键盘映射空值异常，堆栈位于浏览器key/location转换；日期输入和后续查询正常，未据此声称控制台全无异常。
- 最终运行态完成查询区背景/文字对比度修正，隔离浏览器清理旧Service Worker缓存后复验，查询成功且控制台无错误/警告；[运行态截图](evidence/20261027-external-data/runtime.png)。原用户浏览器未刷新，评审前应先保存草稿再重新加载新版。

## 验收边界

固定18153及桌面双入口更新至dist/Universal-HMI-ExternalData-20261027，保留原工程目录与PostgreSQL。升级前备份为.local/postgres/backups/20261027-144407-password-policy；新连接密钥也随验收备份。测试服务和独立SQL Server容器已停止，合成测试数据未加入原工程。

现场SQL连接、真实索引/数据量性能、证书及账号权限尚未验收；本批原生鼠标/高DPI未另行验证。当前仅支持明确的KIOHistory站区采样契约，无任意SQL入口、历史定义版本、跨站整张总表、日/月聚合、全区间趋势降采样或外数据导出。分页为当前库读取，不承诺查询期间并发补写的跨页快照。现场旧槽位不可复用为不同语义而仍期待本系统还原旧定义。
