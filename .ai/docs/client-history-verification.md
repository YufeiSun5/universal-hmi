# 客户端四入口与外部历史（2026-10-29）

产品要求见 [agent.md](../../agent.md)，唯一契约见 [architecture.md](architecture.md)。本批由主代理调度和审查，GPT-6.1 Terra 实施 Flutter，GPT-6.1 Sol 准备发行与隔离验证。

## 实现

客户端仅提供 GIS、工艺画面、设备台账、历史。历史复用现有 externaldata 目录、逐小时日报、明细及趋势查询，保留独立画面授权。未配置、无授权、无采样或外部查询错误均不回退内部历史。

工程师明确打开 runtime 客户端也采用相同导航；初始化、刷新和切站不读取内部历史目录、文件任务、存储策略或事件。外部来源管理仅开发端读取，避免管理接口故障阻断客户端历史目录。默认开发入口及 KP 既有语义保持。

内部历史、报表、曲线、变量与存储工具保留在开发端；Go 查询、授权、采集与存储规则未改动，没有删除历史数据或停止后台存储。账号安全、连接和退出保留为外壳操作。

## 验证状态

- Flutter 完整 253 项通过；最终来源读取分流修正及补充回归后，客户端/外部历史专项 11 项通过，analyze 无问题。专项包含切站保持工艺页、查询成功和错误无内部回退、600×600 四入口、默认工程师开发入口。
- 原 SQL Server 2019 隔离容器复用合成数据，18164 独立工程通过公开 API 查询日报24行、明细和趋势各500+1行分页；未连接现场数据库。
- Windows/Web fresh release同源构建、format/analyze及发行15步骤通过，源码摘要 `a4407c04cac8d53b8d9d1d6c7cc1ffcf2c8ae31ab9505da48bf2bd7364a5a1d9`。Go业务未修改；fresh编译的服务与v8已验服务逐字相同。完整[发行证据](evidence/20261029-client-history-release/build-result.json)。
- Chrome实际查询日报24行、趋势500+1翻页，1440×900与600×600四入口、开发端内部工具保留通过。关闭隔离SQL后显示明确连接失败，无内部回退；请求日志没有内部history/jobs/storage/events或external/sources。控制台仅此次故障注入产生的预期422，没有观察到其他错误。[请求证据](evidence/20261029-client-history/browser-requests.txt)、[日报](evidence/20261029-client-history/client-history-daily.png)、[趋势](evidence/20261029-client-history/client-history-trend.png)、[窄窗](evidence/20261029-client-history/client-history-narrow.png)、[错误](evidence/20261029-client-history/client-history-error.png)、[开发端](evidence/20261029-client-history/client-history-developer.png)。

## 交付与升级

后续完整安装器已完成并通过v8→v9实际覆盖验收，当前仅交付[v9完整安装EXE](windows-full-release-20261029-v9.md)。下方ZIP及“未制作新安装EXE”描述为本功能构建完成时的历史状态；最新安装器包含本轮应用及展开后的绑定资料，无需解压。

固定18153已运行 `dist/Universal-HMI-ClientHistory-20261029`（PID3908），桌面本地/远程开发与运行四入口已更新并备份原快捷方式。升级前备份 `.local/postgres/backups/20261029-172730-client-history`，升级后PG11表摘要不变（1账号、4站点、3文档、25审计），项目其他配置与引用文件字节保持，HTTP实际Web与包清单匹配，GIS5204文件与旧live完全一致。公网仍默认关闭。见[部署核验](evidence/20261029-client-history/final-deployment-evidence.json)。

桌面ZIP：`dist/Universal-HMI-ClientHistory-20261029-Windows-x64.zip`，207176355字节、6293文件，SHA256 `4eea33da4b98405744ff413cbf24b4323ffad17e333e5052b8b2d54539e59868`，逐项校验与stage一致，包含最新KingIO绑定资料ZIP，未自动导入。没有制作新安装EXE；旧v8安装包仍是上一版，不能称含本轮客户端改动。

原窗口未关闭、浏览器原页未刷新。测试18164、独立Chrome及SQL容器已关闭；测试源和合成数据没有写入原18153工程。当前运行客户端需要保存草稿后从托盘明确退出，再通过原快捷方式打开新版。

## 范围

本批复用首批 KIOHistory 外部历史能力，查询时间限制、分页、质量语义与当前页趋势保持，详见 [外部数据验证](external-data-verification.md)。真实现场连接、长期容量、原生鼠标/高 DPI 与公网环境本轮未验。
