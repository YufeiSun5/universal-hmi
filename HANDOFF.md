# Universal HMI → Dot 交接

用户在 2026-10-01 明确要求由 Dot 接手。本轮已停止新增功能；本文件是交接记录，产品母本仍为 agent.md，活跃任务仍只维护 AI_BOARD.md。当前会话没有直接指派 Dot 的工具，不表示 Dot 已接收任务。

## 用户目标

完成“通用临时上位机平台”第一版：Go 后端 + Flutter PC 优先、兼容浏览器，Linux 先开发调试，Windows 最终构建。专业紧凑桌面体验参考 VS Code/Figma。主要数据添加、采集/下设、缩放偏移、虚拟点、条件事件、独立存储、图表、Excel 分析/筛选/导出跑通，完成可运行版本后让用户评审。用户已授权实施和 public 仓库写入，无需重复请求启动批准。

## 代码与读取顺序

仓库：https://github.com/YufeiSun5/universal-hmi ，分支 main。

最后功能源码：899a12e1cde1849c20e3acb268fbf86d06ece980；其前一批 0f4cb9c 回填了真实 Go/Dart 格式化结果、依赖锁与 Linux runner，并提交布局、演示采集及包装测试改进。此交接提交只修改文档/截图，不修改应用行为。

先读 AGENTS.md → agent.md → MEMORY.md → AI_BOARD.md → .ai/docs/architecture.md；实现约束在 .ai/instructions/，接入合同见 .ai/docs/protocols.md。按现有工程持续实施，不再次初始化。

## 已有实现

- backend/internal/points：配置、稳定身份、类型/单位/源路径/倍率/偏移/可写属性，JSON 原子落盘；保存和运行激活分开。
- acquisition：generic/Kepware values/KingIO Objs MQTT 规范化，不默认坏质量为正常。
- runtime：运行版激活、受限虚拟表达式与依赖检查、受控逆算写入与命令去重、AND/OR/持续/冷却/边沿/周期/恢复、逐步动作结果、独立存储和显式 30 站模拟。
- storage：SQLite WAL，冻结历史、目录、过滤分页/统计、配置策略与执行记录。
- analysis：CSV/XLSX 工作表及列映射预览、校验后幂等导入、有界异步导出、取消/下载/删除。
- server/platform.go 与 cmd/server：本机 HTTP 装配；默认 127.0.0.1:18080，Web 静态服务。
- app：工作空间、工程树、点位表、属性、趋势、事件/来源/存储、导入与报表任务、主题、快捷键、可调面板、平台文件适配及自动 sidecar。
- ci：Linux/Windows Go，Flutter Web/Linux/Windows，Linux 原生集成、本地 MQTT、Chromium 文件交互、最终包组合与 Linux 自动启动验证。

这是 SPT 通用能力参考审阅后的新通用实现，没有完成 SPT 后端全量迁移。用户确认 SPT 有独立存储；具体 Lite 源码仍待定位，不能把其文档当作迁入证据。

## 证据与当前 CI

已完整通过：b47fc66 的 [CI 36801113430](https://github.com/YufeiSun5/universal-hmi/actions/runs/36801113430)，6/6，实际流程/下载/截图见 .ai/docs/v0.1.md。

当前功能源码的 [CI 36883999289](https://github.com/YufeiSun5/universal-hmi/actions/runs/36883999289)：交接检查时 Go Linux/Windows、Flutter Web/Windows 已 success；Flutter Linux 仍在运行；packages 等待。接手先读取最终结果，失败则看对应 job 日志，不沿用上一轮成功结论。

当前工作流仍在 CI 中 tidy/gofmt/Dart fix/format/flutter create。上一轮产生的实际源码/lock 已回填，但本轮格式化变化须再次核对，移除修改步骤，再按固定源码/锁复验。不要把临时修改后的 build 当原提交逐字构建通过。

会话 Linux 环境启动失败，只有 GitHub API 能用；本轮全部执行来自 Actions 虚拟机。Dot 若有正常 Linux executor，应 clone 后安装固定工具链，直接运行/调试 Flutter native，并截图评审。

## 接手优先次序

1. 读取 36883999289 最终 jobs 和 artifact，核对新 30 站原生截图、Web 深浅色截图、最终包自动 sidecar/同源 Web 验证。
2. 获取 CI 输出 HMI_FILE 的格式化源码和 lock 差异并提交；只读门禁改为 go mod verify / go test -mod=readonly -race / go vet / build、flutter pub get --enforce-lockfile、dart format --output=none --set-exit-if-changed、analyze/test/build。移除常规 CI 的 create/tidy/fix/写格式步骤；保留标准 runner。
3. 在可用 Linux 环境实际运行，检查点位、规则编辑、右键/快捷键、面板、图表、原生文件对话框、退出/已有服务复用；修复实际问题。已有测试重复通过后只在新改动/失败需要时复验。
4. Windows 保留独立构建；人工窗口/文件/DPI 和首次启动与 Linux 自动证据分别报告。
5. 同一批更新 MEMORY/AI_BOARD/架构；把最终 SHA、CI、产物摘要、截图更新进 v0.1.md，完成第一版后向用户提供具体版本评审。

## 运行

工具链：Go 1.24.7，Flutter 3.35.4 / Dart 3.9；pubspec.lock、go.sum 已提交。

开发先在 backend/：go run ./cmd/server --data-dir .local。
app/：flutter pub get --enforce-lockfile；flutter run -d linux。
打包后的 ./universal_hmi 自动启动包内 Go；浏览器访问 http://127.0.0.1:18080。
完整依赖、检查命令与测试脚本见 .ai/docs/verification.md。

## 已知范围和缺口

当前一个本地工程、多逻辑站，尚无独立多工程隔离/切换。Kep/KingIO 只读既定格式；物理写只有 generic 命令。sent 仅 broker 收到，不代表设备 ACK；未知命令不自动重放。真实来源不自动连接，重启规则禁用，独立存储无需检测或 UI。厂商协议、真实负载、远程认证待后续证据。

仍有点位发现/批量工程导入、历史全区间降采样、曲线与表格联动、排序/复杂 Excel 模板等产品目标；第一版不可宣称全部实现。事件是声明式条件/受控动作，虚拟公式受限，不支持任意系统脚本。

不要连接现场生产设备或加载客户凭据来完成演示；现有 Mosquitto 与模拟数据已足以检验通用流程。
