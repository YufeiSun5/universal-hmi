# 工程重建、谨慎删除与 MQTT 扫描后匹配（v11 修正版）

状态：v11 修正版实现、审查和隔离安装验收通过，交付完整 EXE；现场升级未执行。本文记录实际证据，不替代 [产品母本](../../agent.md)、[架构](architecture.md) 和 [唯一看板](../../AI_BOARD.md)。

**实际安装验收退回：** 下方 v10 安装包未交付。静默覆盖的 11 表保留及删除引用/冲突通过，但显式维护在私有 PG 已启动后读取其 stdout 时遇到后代进程继承的文件锁，尚未调用 Go 重建工具即失败；完整备份保留、启动闭锁有效。此前模拟脚本测试没有覆盖此句柄继承。Sol 已修复维护输出读取和安装器失败退出码，并通过真实 PG 回归及完整安装验收，修正版发行身份为 v11（0.1.0.11）；固定清理标记仍为 `process-rebuild-v10`。失败安装包与全部隔离尝试保留供诊断。

## 用户确认的流程

保留原 MQTT 来源，从该来源扫描添加实际变量，确认取数，再建业务站、导入工艺画面并引用扫描得到的变量。扫描表单当前仍需要填写变量归属组，可使用用户实际的数据源归档组；这与工艺画面的业务站分别处理，不自动按 KingIO 路径创建分组，不创建无归属变量。

新资料使用 `match_existing`，以选定实际来源及完整 KIO 路径匹配，唯一且兼容才引用。包内变量定义只作匹配依据，不默认再创建一批变量。实际现场点表未取得，不能用合成测试宣称现场全部匹配。

## 本轮边界

- Sol 实施后端、离线维护与发行，Terra 实施 Flutter 和隔离验收；root 调度、审查。
- 只制作完整 EXE 和展开资料，不交付 ZIP。
- 一次性工程清理先完整冷备并逐文件校验，再执行单事务重建；失败阻止普通启动，成功标记避免重复清空。
- 保留 MQTT、GIS 布局/素材、身份权限、公网配置/密钥、历史。删除旧变量定义、非 GIS 工艺和站点目录；处理失效绑定及规则/存储引用。设备资产/图片保留，解除旧点关联。
- 日常删站不级联；当前引用阻止删除，界面输入准确站名确认。批量删点先预览并检查版本和引用，整批成功或整批不删，不自动应用运行配置。
- 不访问服务器现场，不改本机 18153 工程。安装器验收使用 `.local/full-v10-installer-verification`、`.local/full-v11-installer-verification` 等隔离工程。

## 核验证据与未验范围

| 项目 | 当前状态 |
| --- | --- |
| Flutter 全量测试 | Terra 报告固定 3.35.4 的 263 项通过；最终纯显示文案修改后 analyze 通过 |
| 匹配已有变量 | Go 1.24.7 全量 test/vet 通过；623 合成扫描点及推荐资料解析专项通过，28 画面/471 绑定引用原 ID，变量不增改，重复导入不增修订 |
| 并发删除保护 | root 发现引用检查与删除间隙及单删绕过，已修正；真实 HTTP 并发保存规则/存储/设备/画面及站点旧编辑场景通过，含合法 ID 为 sample 的路径 |
| CLI 数据库归属与备份校验 | 实际 PG18 隔离验证通过：status/plan 只读、过期计划及损坏备份拒绝且全表不变、错误 cluster 拒绝、提交及重复标记通过；身份/历史/审计等 9 表摘要不变。证据 `.local/v10-cli-fixture/backend-evidence/verification.json` |
| 维护脚本故障保护 | 8 项通过（`.local/v10-reset-tests/script-tests.log`）：备份及重复执行、失败闭锁/恢复、完成凭据与 DB 标记冲突、junction 拒绝、原生退出码及超时终止。PG/CLI 使用模拟工具的脚本测试，不等同完整安装器验收 |
| 完整安装器升级、冷备恢复与一次性标记 | 最终 v11 实际 EXE 隔离 v9→v11 通过：不重建时 623 合成扫描点和 PG 11 表摘要不变；显式重建保留 MQTT/GIS/账号权限/可查询历史，清旧配置；完整冷备逐文件校验及实际恢复、引用阻断/整批原子、重装保留新配置、卸载保留工程通过。原快捷方式恢复、隔离端口释放。[完整安装验收](evidence/20261029-process-match-fix-full-v11/installer-verification.json) |
| Windows/Web 新构建、完整 EXE | 冻结源码 `9c50cfc1a82ff4d94fc3875c9e9d05b5f3ae74b4dbf86b11e3211f477ca3c4e5`；Go/Windows/Web 全新构建通过，GIS 5204 文件与原部署一致、PG18.6 的 3059 文件核验通过；9 个资料普通文件无 ZIP。完整包已生成，最终实际安装验收通过 |
| 实际 Web 删除交互 | root 在独立 18082/PG55434 全新工程，以同一 9c50 应用字节完成：引用站禁删、空站空输入/错误名称禁删/准确名称成功、3 点含引用整批禁删、筛选 2 点预览并成功删除、保留引用点并显示未应用配置；850×600 对话框可见且可操作。截图 `output/playwright/v11-station-blocked.png`、`v11-station-confirmed-name.png`、`v11-batch-blocked.png`、`v11-batch-ready.png`、`v11-batch-result.png`、`v11-batch-small.png` |
| 现场 MQTT、真实服务器升级 | 未执行 |

2026-10-29 重新读取远端最新 CI：`38031925060` / `f552d81cece70a3bc7f4287b228e15bbdd6c2108` 为 success，但不覆盖本轮工作树，不能代替本轮门禁。

## 发行身份

本轮交付为修正版 v11：`dist/installers/full-20261029-v11/Universal-HMI-20261029-Full-v11-Setup.exe`，版本 `0.1.0.11`，225088911 字节，SHA256 `2cc1a11563570924368d3354da91d0f68edbb2074db6c44b5cbe54ddf0ea3426`（root 独立核对）。应用复用本轮已经全新构建并验过的 `9c50cfc1…` 字节，仅维护脚本与安装部署变更；当前源码摘要 `d59290826362d3fcba26760ecea5ea8ca6a10254af73737c40a6ff8002d8a8bb`，新 deployment `fbbbbc88be1651cb6c1ae4bfc53ee155ad60b2114d9ab20ed4655765216574bb`。不得将部署修复称为再次全编译。

修复增加仅 Go CLI 显式读取 JSON 输出、PG 控制命令不读后代仍持有的 stdout、脱敏维护阶段/异常类型/栈日志、安装器维护失败返回码 42。真实 PG18.6 主维护首次 applied/重复 already_applied、1354 文件完整备份校验、9 项脚本回归及独立小 Inno 故意失败退出 42 已通过。发行证据：[v11 release-verification.json](evidence/20261029-process-match-fix-full-v11/release-verification.json)。最终完整安装器验收通过：[installer-verification.json](evidence/20261029-process-match-fix-full-v11/installer-verification.json)。本轮未测安装器交互界面及原生 GUI；root 另行完成实际 Web 删除交互检查。

以下为**未交付的失败 v10** 身份，保留诊断：

- 安装器：`dist/installers/full-20261029-v10/Universal-HMI-20261029-Full-v10-Setup.exe`，版本 `0.1.0.10`，225088272 字节。
- SHA256：`76db7be605f27510033240152e851b6107d8228084ffb63878a178e4660bb9f5`，root 独立读取核对。
- payload：`9c50cfc1a82f-pg-6e347c1e50cc`；deployment：`6e347c1e50cc288216d06a600616ea1ab8c388ad2b96821bdbc4dbe250606dde`。
- 发行核验：[release-verification.json](evidence/20261029-process-match-fix-release-v10/release-verification.json)。安装器未签名，WebView2 沿用外部前置依赖。
