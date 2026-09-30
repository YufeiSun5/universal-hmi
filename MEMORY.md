# 当前上下文

更新：2026-09-30。

- 名称：通用临时上位机平台；仓库 universal-hmi，public。
- 用户已创建空仓库并授权按 dotai-scaffold 初始化；产品要求以 agent.md 为母本。
- 技术目标：Go + Flutter desktop/web，PC 优先，现代专业工作空间参考 VS Code / Figma 桌面端。
- 能力目标：数据添加/管理、采集换算、物理下设、虚拟点、条件事件脚本、独立存储、图表、Excel 分析、筛选与导出。
- 原 SPT 检测启动/判定等属于特殊业务，不迁入；存储不依赖用户开始检测。
- SPT 已审到的正式版 main 快照：86173ae7784c55b303691a951dc65c35ccccc98e。该快照有 MQTT、项目归属、换算、任务流及 KingIO 写服务。独立存储具体实现待定位，不将上游正式版和 Lite 文档混为当前实现证据。
- 用户追加授权工程骨架与实际编译验收。已准备 Go stdlib 本地 API（文件持久配置）、Flutter desktop/web 导航/主题/状态及点位添加流程；SPT 尚未迁入，无设备连接或迁移。验证结果以初始化记录和 CI 为准。
- 首个桌面打包目标暂按 Windows 规划；macOS/Linux 的承诺范围待确认，架构保留平台适配。
- 总点数、更新频率、历史保留、实际 MQTT/下发协议、Excel 样例和浏览器部署拓扑待确认，不阻止文档初始化。
- 执行环境当前离线；文档可经 GitHub 工具提交，Go/Flutter 构建与运行验证尚不能执行。
- 活动任务及阻碍只维护在 AI_BOARD.md；稳定设计见 .ai/docs/architecture.md。

工程工具链固定 Go 1.24.7、Flutter 3.35.4。第一轮 CI 36757831630：Linux Go test/vet/build、Flutter Web/Windows analyze/test/release build 均成功。标准平台文件、pubspec.lock 与 gofmt 输出由固定工具链生成后回填；最终提交独立验证，结果见初始化记录。
