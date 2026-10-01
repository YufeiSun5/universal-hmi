# 验证与发布条件

母本：[架构](architecture.md)、[桌面体验](desktop-experience.md)。本阶段结果与产物见 [v0.1.md](v0.1.md)。

## 固定工具链与检查

Go 1.24.7，在 backend/：
~~~sh
go mod verify
go test -mod=readonly -race ./...
go vet -mod=readonly ./...
go build -mod=readonly ./cmd/server
~~~
gofmt 检查 cmd、internal 无未格式化文件。这是待 Dot 完成的只读门禁目标。当前 CI 仍执行 go mod tidy / gofmt 与 Dart format / fix，已将上一轮生成的源码和锁文件回填；本轮格式化差异需核对提交，再删除这些修改步骤。当前 CI 成功不能替代未修改源码的最终复验。

Flutter 3.35.4 / Dart 3.9，在 app/：
~~~sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test test
flutter build linux --release
flutter build web --release
~~~
Windows 在 Windows + Visual Studio C++ 工具链执行 flutter build windows --release。标准 Linux/Windows/Web runner 和真实 lock 已提交；当前工作流仍有 flutter create 临时生成步骤，Dot 接手后移除并以现有 runner 直接构建。

Linux 依赖 clang、cmake、ninja-build、pkg-config、libgtk-3-dev、liblzma-dev；自动图形交互使用 Xvfb，中文字体用 Noto CJK。浏览器自动操作使用 Playwright 1.55 / Chromium。本地 MQTT 使用 Mosquitto，与任何现场设备分离。

## 流程与门禁

| 层次 | 核查 |
| --- | --- |
| Go 回归 | 原子配置持久、类型/范围/逆算/配置版本、命令去重、坏质量与持续条件、虚拟循环、陈旧/乱序、模拟设定值保值与停止后陈旧 |
| 历史/文件回归 | 无检测前置、冻结历史语义、重复导入幂等、错误行阻止提交、Excel serial 时间、安全外来字符串、取消不覆盖、统计排除坏质量、空边界冻结 |
| widget | 草稿只在显式应用生效；非法表单可修正；离线/窄布局/长标签无溢出 |
| Linux 原生 | ci/run_linux_ui.py 调真实 runner：添加→保存→应用→后端采样→快照→历史→报表任务；两个窗口尺寸；实际 release 截图 |
| MQTT 集成 | ci/smoke.py：10 站 packed Kep、换算、虚拟均值、坏质量不触发、AND 持续条件、逐步动作、历史及 XLSX、generic 发送与去重、读回不伪造 |
| Chromium | ci/browser_flow.py：真实文件选择→上传→列映射预览→导入→数值筛选→统计/图表→下载 XLSX，并解压重读实际数值 |
| 发布包 | ci/package_final.py 组装 desktop + Go + Web；ci/package_smoke.py 启动最终 Linux bundle，验证自动后端、同源 Web、30 站/90 点及独立存储 |
| 文档 | 相对链接、需求/架构母本唯一、现状与目标、证据和活跃看板一致 |

模拟或构建结果不替代 Windows 人工操作、DPI/生命周期、生产厂商协议、认证远程部署和容量验收。既有 SPT 测试不替代本项目验证。

每次记录提交、运行环境、工具链、实际操作、日志/产物与 passed / failed / unexecuted / blocked；会话环境启动失败与 CI 虚拟机可运行分别报告。
