# GIS 公共驾驶舱归属验证

日期：2026-10-27。需求母本为 [agent.md](../../agent.md)，技术合同为 [架构](architecture.md#gis-公共驾驶舱2026-10-27)。

用户明确 GIS 是跨站汇总的工程级公共驾驶舱，不归属某个站点。既有用户端首页 GIS 已符合此定位，旧开发表单和后端保存仍允许站点 GIS，本批收紧这两个入口。

## 实现

- `app/lib/features/process/create_screen.dart`：站点添加画面只提供工艺图，并说明公共 GIS 创建入口；公共创建仍提供工艺图和 GIS，GIS 明示驾驶舱定位，保存的 station 固定为空。
- `app/lib/features/process/screen_explorer.dart`：公共目录维护 GIS，底部说明 GIS 与可跨站复用的工艺布局用途。
- `backend/internal/process/screens.go`：共享保存用例拒绝任何非空 station 的 GIS；不静默改写请求归属。HTTP/MCP 同用此用例。
- 旧站点 GIS 仅兼容读取且保留原权限，不自动改公共、不因启动扩大可见性，继续以旧归属保存会明确报错。后端回归通过手工准备旧持久化文件验证这一点。
- 公共 GIS 不代表可查看全站数据，原变量与跳转授权不变。本次不新增驾驶舱统计指标或修改现场控制。

## 当前工程

升级前只读核对 PostgreSQL documents：3条记录包含点位定义、示例站01的工艺画面和公共站区地图；唯一 GIS 的 station 为空。无需迁移既有画面或更改用户授权。

## 验证状态

Go 全量测试及 vet：passed。Flutter analyze、193项全量测试：passed。Windows/Web release构建同源摘要 `0d6629cff9a1cf4106f5914a2dd176587bac831726b7715542a25d3a2dcb7216`：passed。原生鼠标/DPI本批未重验，不以构建代替现场验收。

隔离HTTP（18157、新数据目录和临时账号）：公共GIS保存成功，带站点的GIS被拒绝且未写入。见[接口结果](evidence/20261027-gis-public/http.json)。

隔离Chrome实际操作：站点添加表单展开后仅“工艺图”；公共表单切换GIS并创建“全工程驾驶舱”，目录与页签均在公共范围，API回读station为空。截图：[站点入口](evidence/20261027-gis-public/station.png)、[公共入口](evidence/20261027-gis-public/public.png)。仅测试工程新增画面，原用户浏览器未刷新，测试页及测试后端已关闭。

发行包最终校验及固定18153升级：passed。首次封装发现Windows构建目录遗留后端的摘要与新后端不一致；重新验证当前Windows产物并重新封装，最终桌面/Web源码及产物摘要一致。

固定18153在15:13启动新版本 `dist/Universal-HMI-GISPublic-20261027`（PID26200）；桌面双入口通过原project.json指向同一版本，仍使用原data和PostgreSQL配置。备份为 `.local/postgres/backups/20261027-150824-password-policy`（沿用旧脚本目录后缀），包含数据库、身份密钥、外数据连接密钥及旧启动配置。升级前后11张表数量与逻辑摘要全部一致，保留1账号、4站点、3条工程文档记录。served main.dart.js与发行包逐字一致，旧版本目录保留可回滚。见[部署证据](evidence/20261027-gis-public/deployment.json)。

新增/调整回归覆盖：站点表单无 GIS 选项，公共创建 GIS 的 station 为空，站点 GIS 保存被拒绝，旧文档读取保持原归属，公共 GIS 坐标/变量绑定及版本冲突保持。
