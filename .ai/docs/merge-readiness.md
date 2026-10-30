# PR #14 合并核验（2026-10-30）

接手基点：main `b8d3b77cce3be4aba758e8e019d47d7ad38aeca5`，PR head `71b14c2dad4b8203ae2eaf151bd8dbc613e7b4b7`。PR 已包含至 v19 的源码，旧 PR 正文仍描述 f552d81，不能用其历史通过陈述验收本次 head。唯一活跃状态仍在 [AI_BOARD.md](../../AI_BOARD.md)。

## 实际失败与修正

- [Verify 41073942894](https://github.com/YufeiSun5/universal-hmi/actions/runs/41073942894)：Windows Go success；macOS `TestBackupExactSetChecksumAndSafePaths/valid` 因临时根的 `/var` 系统链接失败。本机固定 Go 1.24.7/race 重现。只对测试夹具使用真实路径；生产 noLinks 不改，追加祖先链接拒绝测试。Python 的进程/CRT 测试夹具采用同一真实临时根，消除本机同类误报。
- 同一 run 的 Linux 可执行 MCP 测试仍期望 40，实际 45。改成明确的工具名集合及重复名检查，新增的五项为 station_create、navigation_get、navigation_save、source_discovery、point_write_capability；保留只读拒绝、写入显式开启及非法 envelope 检查。
- [Lifecycle 41073942482](https://github.com/YufeiSun5/universal-hmi/actions/runs/41073942482)：已完成 release build，后续 demo POST 未登录而返回 401。夹具在全新临时工程通过公开 setup/login 建立随机临时账号，使用 bearer 执行业务，不关闭认证。复用后端显式开启相同 identity 模式与精确 public-origin。新增真实 HTTP 回归核对匿名 401、登录 200、已有账号不再初始化、注销 401、重启不丢账号；保留原有渲染排空/退出码/后端所有权断言。

这些是驱动和测试夹具漂移；本批没有修改生产业务、权限、序列化、迁移或安装器行为。后续精确 head 的完整 CI 和 Linux 实际窗口关闭仍须通过，不能以单元测试替代。

## 兼容性审查范围

- 配置/导出：process schema_version=1 及可选字段继续由 `internal/process` 验证；旧空 kind 仍按 process，GIS zones 等可选项有专门旧文档测试。模板与迁移包保持独立、显式 preview/commit，不按同名自动绑定。实际 JSON 及旧 main 工程升级的证据另行记录。
- 数据库：SQLite 仍可运行；`persistence.ImportLegacy` 仅显式 migrate-sqlite 导入停止的旧工程到空 PG，目标非空拒绝、来源只读、事务提交前核验文档字节。正常启动不调用离线 rebuild。PG18/Windows 一体安装兼容依据为仓库 v19 历史记录，本机没有 PG/PowerShell，不将其计为本批实际通过。
- 接口/控制：HTTP/MCP 复用公开业务接口，MCP 默认只读；设备写入与保存/Apply 分离。未连接现场 MQTT、SQL Server、KP 或其他设备；KP verifier 的 TLS/身份及会话分离由本地契约测试覆盖，真实 KP/多机仍需现场证据。
- 安装/回退：本批只修验证入口，不重建、迁入或清理用户工程，不运行旧安装器重建开关。不把源码合并视为安装升级或现场发布授权。数据库发生迁移后的程序/数据回退须结合对应备份与版本验收，不承诺任意旧二进制可回读新数据。

## 本机检查

环境 macOS arm64；固定 Go 1.24.7，独立 `/tmp/hmi-go-*` 缓存；Python 3.9，Node 本机工具。完整 Go race/vet/build 和 go mod verify 已执行；真实 PG/MQTT 依赖测试缺少配置/工具时保留各自 skip，不计为现场通过。Go 最初非提升运行的 socket/依赖失败与后续有回环权限的成功分别计证。

可执行 HTTP 9 项（包括新账号夹具）、进程/关闭证据 5 项、CRT 16 项、macOS 封装 13 项、installer smoke 18 项、素材 3 项、KP 脚本模拟 18 项通过；安装器 27 项中 9 项因本机非 Linux/Windows 工具缺失而 skip。发布门禁故障测试和新的远端 CI 结果以后续记录为准。没有本机 Flutter SDK/Linux 显示服务，不冒充实际原生或 Web 人工操作通过。
