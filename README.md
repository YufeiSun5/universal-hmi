# 通用临时上位机平台 · Universal HMI

Go + Flutter 的通用采集、控制和数据分析平台。首先是一款 PC 软件，同时支持浏览器访问。

面向现场调试、临时工程和多 IO 站点的数据接入、点位管理、条件控制、独立存储、趋势图表及 Excel 数据/报表分析、筛选与导出。参考 VS Code 与 Figma 桌面端的工作空间、信息密度和交互品质，发挥 Flutter 桌面能力。

## 当前状态

当前已完成可编译骨架：Go 本地配置 API、Flutter desktop/web 工作空间、点位添加与文件保存。采集、事件、历史、图表和 Excel 模块尚未实现，界面明确显示未启用。Go 底座计划选择性复用 [edge-terminal-SPT](https://github.com/YufeiSun5/edge-terminal-SPT)；独立存储对应实现仍需定位。检测启动、检测标准、合格判定和检测报表属于原项目特殊业务，不迁入本项目。

## 项目入口

- [产品要求与长期约束](agent.md)：用户要求的根目录权威入口。
- [编码工具入口](AGENTS.md)：读取顺序、模块导航与验证。
- [架构及分层契约](.ai/docs/architecture.md)：唯一架构母本，含两条核心流程。
- [桌面设计与交互要求](.ai/docs/desktop-experience.md)。
- [验证与发布条件](.ai/docs/verification.md)。
- [当前上下文](MEMORY.md)与[唯一活跃看板](AI_BOARD.md)。

## 计划代码结构

以下为计划位置，不代表已实现：

```text
backend/                 Go 模块化单体、API、采集及后台运行
app/                     Flutter desktop / web
.ai/instructions/        工作流与实现约束
.ai/docs/                架构、设计及验证母本
```

桌面运行：Flutter 壳管理本地 Go sidecar 生命周期；关闭窗口与退出进程需区分。
浏览器运行：Go 服务提供认证 API、实时连接及 Flutter Web 静态资源；远程部署与访问显式配置。

## 初始化来源

采用 [dotai-scaffold 中文项目设计提示词](https://github.com/YufeiSun5/dotai-scaffold/blob/main/prompt-zh.txt)，源文件 blob SHA：`d34a84e7ad485c726274a92c9f798c3bdf61a886`。本仓库将其约束适配为自己的产品要求和架构文档，不宣称上游实现已迁入或已验证。

public 为仓库可见性；本项目开源许可证尚未选定，迁入代码前核对并保留来源许可证。

## 开发与构建

工具链初始固定为 Go 1.24.7、Flutter 3.35.4 / Dart 3.9；CI 在 Linux 与 Windows 虚拟机分别验证。完整命令和平台限制见 [验证文档](.ai/docs/verification.md)。

Go 服务（先单独启动，sidecar 生命周期尚未实现）：

```sh
cd backend
go run ./cmd/server
```

Flutter 工程已包含 Windows/Web 平台 runner 和依赖锁文件，在 app/ 内：

```sh
flutter pub get
flutter run -d windows
```

浏览器开发时使用固定端口，如 flutter run -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://127.0.0.1:18080，并用 Go 的 -dev-origin http://localhost:5173 显式允许该开发来源（以实际地址为准）。

构建后的 Web 可由同一个 Go 服务提供：在 backend/ 执行 go run ./cmd/server -web-dir ../app/build/web，然后访问 http://127.0.0.1:18080。骨架仅回环监听，远程访问需先实现认证；不要绑定公网。

点位配置写入 backend/.local/points.json；配置保存不表示已有采集或写入设备。代码没有模拟实时值或假图表。

## 已验证构建

源码 72f061e：[CI 36759279670](https://github.com/YufeiSun5/universal-hmi/actions/runs/36759279670) 的 Linux/Windows Go 与 Flutter Web/Windows 共四项全部通过，产物可在该运行页面下载。详细环境、范围与摘要见[初始化记录](.ai/docs/initialization.md)。这是工程骨架编译验收，不是完整产品或现场验收。
