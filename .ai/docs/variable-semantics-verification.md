# 变量派生与站点存储核验（2026-10-26）

本文件只记录实现与证据，不另建产品要求或技术合同。产品母本为 [agent.md](../../agent.md)，技术语义见[架构合同](architecture.md#变量归属派生与存储)，缺口以 [AI_BOARD.md](../../AI_BOARD.md) 为准。

## 结论与边界

当前 Go 后端支持同一共享工程内，两个不同站点的虚拟点引用同一个输入点，分别计算 `v[0]*10`、`v[0]/10`，并按各站存储策略保留各自历史。本轮不修改运行代码，不改变用户工程配置。

| 核实事项 | 证据及限定 |
| --- | --- |
| 稳定 ID、站点、公式和输入身份 | [points.go](../../backend/internal/points/points.go) 的 Definition/CreateInput；当前没有 project_id |
| 跨站公式依赖、循环校验、Go 计算 | [engine.go](../../backend/internal/runtime/engine.go) 的 Apply/evaluate；依赖按 ID 查找，没有同站限制，输入取工程值 |
| UI 中计算点配置入口 | [editors.dart](../../app/lib/features/editors.dart) 的 pointEditor 提供公式及带站名的输入选择；[main.dart](../../app/lib/main.dart) 的 add 传入完整 points。这里只核对源码，本轮未执行浏览器/原生 UI 配置验收 |
| 独立站点策略 | [policies.go](../../backend/internal/runtime/policies.go) 的 SetPolicy/storePoliciesLocked；站点策略拒绝其他站点 ID，分别维护周期与变化基线 |
| 历史归属及质量 | [store.go](../../backend/internal/storage/store.go) 的 Sample/Query 保存并筛选站点、point_id、质量和配置摘要；同一个 SQLite 数据库 |
| 虚拟点只读 | points.normalize 拒绝可写虚拟点；[control.go](../../backend/internal/runtime/control.go) 保留受控写能力判断 |

GIS 跨站显示绑定已有[独立验收](screen-workspace-verification.md)；2026-10-29普通工艺图和公共实例的授权跨站绑定另见[迁移验收](process-transfer-verification.md)，不能由本页较早测试推定。多工程隔离/切换及变量使用位置反查未由本轮实现。跨独立工程共享方案未在此确定。保存的配置摘要不等于完整历史公式定义已可还原。

## 本轮回归

新增 [TestSharedInputDerivedStationsStoreIndependentHistory](../../backend/internal/runtime/shared_variable_test.go)，使用临时点表和真实 SQLite；停止后台时钟后驱动同一个生产扫描函数，不连接设备，不依赖 UI，不写用户数据目录。

1. 来源站 X=100，A/B 站各建一个独立 ID 的虚拟点，分别乘 10、除 10，实际查询得到 1000 和 10。
2. A 每 1 秒、B 每 2 秒存储。X 变为 200 后两站实时结果都更新，1 秒时仅 A 新增历史，2 秒时 B 才新增历史；X 本身不被派生计算修改。
3. A 站策略直接选择来源站的 X 被拒绝；引用 X 不自动开启 X 的历史存储。
4. X 变为坏质量后，两站按各自周期保存 bad/空值；此前正常历史保持正常值。
5. A 的公式改为乘 20 并重新应用，恢复 X=100 后 A 新值为 2000、B 为 10；A 的旧值 1000、源时间及旧配置摘要不变，新记录采用新摘要。

已有[虚拟点回归](../../backend/internal/runtime/virtual_regression_test.go)覆盖缺失/坏质量/陈旧及恢复、源时间语义；已有[存储策略回归](../../backend/internal/runtime/policies_regression_test.go)覆盖周期、变化过滤、恢复及错误范围；[存储测试](../../backend/internal/storage/store_test.go)覆盖保留期和异常质量统计。这些与本轮新增测试一同通过 Go 全量测试。

## 执行记录

- **passed**：Go 1.24.7 windows/amd64，backend 内 `go test -mod=readonly ./...`、`go vet -mod=readonly ./...`。全量输出见 [go-test.log](evidence/20261026-variable-semantics/go-test.log)；vet 无诊断、退出码 0。
- **passed**：新增场景首次独立运行使用系统 Go 1.25.5；随后已被固定 Go 1.24.7 全量测试覆盖，不用系统版本结果代替固定门禁。
- **failed → resolved**：首次调用固定 go.exe 时继承系统 GOROOT，出现 1.25.5/1.24.7 编译器不匹配；在验证进程内显式设置 GOROOT/PATH 后上述命令通过。保留[测试失败日志](evidence/20261026-variable-semantics/go-test-toolchain-failed.log)与[vet 失败日志](evidence/20261026-variable-semantics/go-vet-toolchain-failed.log)，未修改全局环境。
- **unexecuted / 本轮不涉及**：Flutter 测试与构建、UI 人工验收、真实设备、跨进程/多工程隔离及发布。仅新增 Go 回归和文档，18153 服务及用户配置未变；当前工作树的验证不冒充远端 CI。
