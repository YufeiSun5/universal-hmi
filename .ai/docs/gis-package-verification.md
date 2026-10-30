# GIS 已绑定但浮窗无值：发行包修复

2026-10-27。用户反馈可以选择变量并保存，工艺图正常，GIS 浮窗始终显示“数据待绑定”。本批属于发行构建模块，不改变采集、点位身份、绑定 API 或工程归属。

## 已确认原因

原 `ci/stage_gis.py` 将生成影像目录 `.local/gis-flight-demo/site-lod` 中的所有展示文件一并复制。该目录保留了早期 `flight.js` 和 `stations.js`，前者没有 `gis-readings` 接收逻辑，后者没有 `setReadings` / `refreshReadings`；卡片固定显示占位信息。旧脚本拖动后导出的站标也没有保留绑定及跳转目标。

仓库 `examples/gis-flight/` 已有完整实现，但此前发行源码摘要没有纳入该目录。产物哈希只能证明被打包文件未改变，不能证明打入了正确版本。因此，之前安装验证的文件摘要通过不代表 GIS 实时浮窗链路通过。

在隔离端口 18158，用原 LoginStyle 包、一个手工 FLOAT 点和一个公共 GIS 文档复现：保存的 `primary_supply` 绑定存在，后端实时值为 good / 62.3℃，旧包卡片仍为“数据待绑定”和破折号。证据见 [复现数据](evidence/20261027-gis-package/before.json) 与 [截图](evidence/20261027-gis-package/before.jpg)。测试数据与用户工程分离。

## 修复

- 展示 HTML、JS、CSS、站标及许可从 `examples/gis-flight/` 获取；生成目录仅提供影像与 Cesium 资源。
- 将 GIS 源文件纳入发行源码清单；Web、最终组合包、含 PG 安装包逐层校验 GIS 源码与实际文件一致。
- HTML 中 JS/CSS 引用带内容摘要版本，Web/Windows 两个嵌入入口加入 `v=bindings-2`，避免继续复用旧地图 HTML 和展示脚本。已有浏览器的 Flutter service worker 升级后需重新载入应用；验收未清除绑定或业务数据。
- 新增五项回归，覆盖旧生成目录污染、实际脚本被改且重新计算产物摘要、缺失/错误源码来源、旧缓存引用及 GIS 源文件入清单。

## 验证状态

Go `go test ./...` / `go vet ./...`、Flutter analyze / 193 项测试通过。Windows 可执行的打包测试集 53 项，跳过 11 项平台专用测试，其余通过。全量 Python 发现运行包含依赖 Linux 可执行文件、macOS 符号链接及 `/proc/cpuinfo` 的用例，当前 Windows 环境不能全过，未将此结果列为通过。

Chrome 实际浮窗验证：缺样本时“已绑定 1/5 项”、数值为空且标注“缺失”；手工样本 62.3 后显示 62.30℃，随后 63.4 在同一个浮窗 DOM 内更新到 63.40℃，无需重开浮窗。新版入口重新打开后仍显示 63.40℃、保存文档 revision 仍为 1，绑定未重写。见 [实时记录](evidence/20261027-gis-package/live.json)、[重新打开记录](evidence/20261027-gis-package/reopened.json) 与 [修复后截图](evidence/20261027-gis-package/after.jpg)。

Windows 原生浮窗交互未完成：自动审批拒绝启动隔离原生客户端（仅返回 `blocked by policy`），确认没有测试窗口启动。Windows release 构建通过不替代此交互验收。

Windows/Web 最终源码摘要为 `47225f8c36030170d7cc6546eb981df37411e0618b38d5ad40d3341cebab4ec4`，最终目录 `dist/Universal-HMI-GISFix-20261027`。组合时曾因构建目录残留的旧 Go 可执行文件摘要被门禁拒绝；重新执行 Windows 构建、配入本批 Go 后端并完整组合校验后通过，没有跳过摘要门禁。

固定 18153 已切换到该目录（PID 74348），桌面双入口的工程配置同步指向它。升级前备份 `20261027-173516-password-policy`（沿用备份脚本目录命名），十一表数量和逻辑摘要一致，保留 1 账号、4 站点、3 份文档；原浏览器未自动刷新。实际 HTTP 返回的地图入口与两份绑定脚本逐字摘要匹配发行包。见 [部署证据](evidence/20261027-gis-package/deployment.json)。

修复版安装程序为 `dist/installers/gis-fix/Universal-HMI-20261027-PG-GISFix-Setup.exe`，版本 0.1.0.4，204253967 字节，SHA256 `c5bef7c289d49610314865def9ba21fd3fa6481afdbc134f37735f5d57438823`。包含与原包相同的私有 PG18.6；无需另装 PG。见 [安装包清单](evidence/20261027-gis-package/installer-manifest.json)。

实际覆盖升级验证通过：在独立目录安装此前 PG 包，使用既有 PG 工程副本启动并记录十一表摘要，停止后安装修复版。解包后的 6265 个应用文件及 3059 个 PG 文件逐一匹配；运行/开发入口通过 `-NoUI` 启动及复用后台，十一表摘要保持。测试库原无账号，不冒称覆盖了原生登录；本机既有账号保留由前述 18153 比较单独证明。卸载后 PG、密钥及旧工程副本逐文件保持；原桌面/开始菜单快捷方式恢复，两个测试后端均停止。见 [升级与卸载证据](evidence/20261027-gis-package/installer-upgrade.json)。

部署时关闭旧客户端，从开始菜单停止后台后覆盖安装；已有 PG 工程继续使用。Web 浏览器重新载入应用，待新版 service worker 生效后再打开 GIS。目标另一台电脑仍需安装后检查其实际绑定和采集；本机隔离验证不替代现场验收。此批结果来自本地构建，既有 GitHub CI 不覆盖当前未提交工作区。
