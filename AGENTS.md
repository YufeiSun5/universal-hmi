# Universal HMI · AI 编码入口

用户要求的产品母本是 [agent.md](agent.md)，先读该文件。小写 agent.md 不保证所有工具自动加载，因此本文件只提供入口，不复制产品要求。

## 必要读取

1. [agent.md](agent.md)：产品范围和长期约束。
2. [MEMORY.md](MEMORY.md)、[AI_BOARD.md](AI_BOARD.md)：当前状态与唯一活跃任务。
3. [.ai/docs/architecture.md](.ai/docs/architecture.md)：唯一分层契约。
4. [.ai/instructions/workflow.md](.ai/instructions/workflow.md)：修改与交接流程。
5. 修改 Go、Flutter 或跨端交互时读 [.ai/instructions/implementation.md](.ai/instructions/implementation.md)；UI 工作还读 [.ai/docs/desktop-experience.md](.ai/docs/desktop-experience.md)。

## 边界

Go 模块化单体负责业务与后台；Flutter desktop/web 负责交互。backend/、app/ 是计划位置，目前未生成应用代码。先声明修改所属模块、边界、路径及检查方法，再实施；跨模块只走公开契约。

SPT 专用检测业务不迁入。独立存储和条件事件保留；物理下设使用后端受控写入服务。不要把保存、发布、应答、读回或文件任务排队当作同一种成功。

## 验证

当前文档：检查相对链接、母本唯一性、目标/现状区分及看板状态。
代码生成后：Go 模块内 go test ./...、go vet ./...；Flutter 内 flutter analyze、flutter test，变更目标的桌面/Web 构建。当前没有 go.mod/pubspec.yaml，这些命令尚不可执行。
完整验收与故障覆盖见 [.ai/docs/verification.md](.ai/docs/verification.md)。

不用空目录或多 Agent 数量衡量完成度。用户已授权本轮初始化；现场控制、数据破坏和授权范围扩大仍需具体方案与既有授权依据。
