# 变量归属整理核验

本轮实现按当前工艺画面引用整理变量归属。画面引用仅为可审查建议，不代表物理设备归属；不按名称猜测全量 5019 点。共享和未引用点默认保留原站，用户明确选择后才迁移。现场工程、18153 和真实 MQTT 未操作。

## 公开契约

`POST /api/v1/points/ownership-preview` 接收 `{"targets":[]}` 分析当前完整目录；选择后以 `targets:[{"id":"稳定ID","revision":"当前修订","station":"已存在目标站"}]` 重新预览。响应包含 `items`（原站、目标站、single/shared/unreferenced、画面与箭头依据、blockers/dependencies）、`counts`、`preview_token`、`can_commit`。

`POST /api/v1/points/ownership-commit` 提交相同 targets 和 preview_token。计划绑定实际定义、画面、站目录、策略、规则及当前操作者身份版本，提交重读并验证；任一变化要求重新预览。成功返回 `saved:true,requires_apply:true,applied:false` 与完整 backup。冲突返回 409 ownership_conflict，权限不足 403，持久化失败 422。现有登录、CSRF、配置修改串行化、未知字段拒绝与 1 MiB 请求限制继续有效。

接口要求现有 Develop 授权，其契约同时要求工程角色和 AllStations；部分站工程账号不能调用，避免隐藏画面导致错误的单站建议。目标站必须已存在；重复 ID、修订过期、目标重名、存储依赖和站范围规则冲突均闭锁。派生输入/使用者作为依赖显示，稳定 ID 及公式不改。

## 保存、备份和删除边界

整批只修改定义 Station；ID、MQTT source/topic/path、数据类型、比例偏移、绑定、画面和历史不变。数据库将恢复记录和定义放在同一事务；文件模式先以 create-only 写入并同步恢复记录，再原子保存定义，备份失败不修改定义。每次备份使用独立随机 ID，包含关联计划 token、全部受影响 ID 的原站/目标站、前后 revision、其余字段摘要及 rollback_targets。文件保存失败允许同计划安全重试，重复迁移/回退不会覆盖旧备份。

回退是使用 backup.rollback_targets 再预览、再提交的普通归属操作；后续编辑、权限或依赖改变仍会阻断，不能绕过冲突检查。提交响应提供普通 JSON 下载数据，持久副本位于 ownership_backups 文档（文件模式为 points 文件同级 ownership-backups）。

提交不自动 Apply，运行定义和当前 live 保持原样。用户主动应用后才切换运行归属；既有 Apply 可能重新取值，不能承诺应用过程无间断。历史永久不重写。源或目标站启用全站存储策略、显式点存储策略、迁移后失效的站范围规则会阻断，不能静默改变周期或停用规则。

旧站仍使用非级联空站检查。运行 active 定义仍归属该站时，删除预览和提交增加 `kind:runtime,property:active_owner_apply_before_delete` 引用并阻断，需先 Apply 再检查。运行快照在存储事务前读取，避免 Store/Engine 锁序倒置；删除 token 包含该快照。

## 已通过

固定工具链 `go version go1.24.7 windows/amd64`，GOROOT 为项目 `.local/toolchains/go-1.24.7/go`，GOTOOLCHAIN=local。

- 全模块 `go test -mod=readonly ./...`：[完整日志](evidence/20261029-point-ownership/go-test.log)。
- 全模块 `go vet -mod=readonly ./...`：[日志](evidence/20261029-point-ownership/go-vet.log)，退出 0，无诊断。
- [针对性测试](evidence/20261029-point-ownership/targeted-tests.log)：单站、共享、未引用、箭头引用；权限、重名、陈旧计划；备份失败不变及重试；迁移/回退/再迁移；仅 Station 改变，active/live、历史样本、画面原字节保持；HTTP 登录/CSRF/reader/超限；Apply 前运行引用阻断删除、Apply 后可删空站。
- 首次全测遇到已有 identity rule 用例失败，保留[首次日志](evidence/20261029-point-ownership/go-test-first-runtime-failure.log)。测试以旧采样时间重置已被规则更新的点，生产乱序保护拒绝样本，测试却未检查 ingest 结果，残留旧值造成误报。仅测试改为停止后台 clock、使用新于当前样本的时间并断言 ingest 成功及重置值；生产授权不改。修复后[连续 20 次](evidence/20261029-point-ownership/runtime-identity-fixed.log)及最终全测通过。

## 后续集成验收（2026-10-30更新）

真实 PostgreSQL 5019 点保留升级、325点迁移/备份/回退/再迁移及主代理浏览器操作已通过，见[综合验收](cross-station-ownership-v13.md)。隔离 HTTP18084/PG55436 已停止，卸载保留工程及原快捷方式恢复通过。本页的 Go 核验不代替集成证据，也不代表现场数据已迁移；本轮原生GUI及现场MQTT未验。公共 GIS、身份、来源配置和实际历史不在迁移写入范围。
