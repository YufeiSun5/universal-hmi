# 初始化记录

日期：2026-09-30。用户明确授权创建 public 项目并按其提示词工程初始化，随后授权实施可编译工程骨架。

来源：dotai-scaffold/prompt-zh.txt，blob d34a84e7ad485c726274a92c9f798c3bdf61a886。未机械复制全目录；采用产品母本、工具入口、当前上下文、唯一看板、架构母本和必要约束。

产品母本为根 agent.md；AGENTS.md 仅引用入口，以适配实际编码工具。架构母本包含模块/层职责、计划路径、公开接口、依赖/禁止项、数据所有权、验证方法和两条核心流程。PC/Web、Flutter 体验、点位添加、存储、图表、Excel 分析/筛选/导出及条件事件均已记录。

不迁入 SPT 检测专用业务；独立存储具体来源待定位。应用初始化与 SPT 迁移分别记录。当前执行环境离线，不伪造本机/虚拟环境构建通过；仓库 CI 结果另附证据。

文档初始化已提交于 57ef20f9ad6eacf712d5e4a951ddddb9c3514142（README 初始提交 9e911f29756d857a878027eee5c24b546722ad84）。初始化文档内部链接检查：24 项通过，无缺失。

第一轮编译：源提交 e55e7aa89be6864cf95e5903299982a3cbed1deb，[CI 36757831630](https://github.com/YufeiSun5/universal-hmi/actions/runs/36757831630) 全部 success：Linux Go 测试/vet/build；Flutter Web 与 Windows analyze、2 项 widget 测试、Release build。Web 和 Windows 产物均上传。

平台初始化来源：[Bootstrap CI 36758600481](https://github.com/YufeiSun5/universal-hmi/actions/runs/36758600481)，分支 bootstrap-native，提交 21c5ad7f2d783f85739719de16ef4ec48e92251f。Windows Go test/vet/build 成功；固定 Flutter 3.35.4 生成标准 Web/Windows runner，pub get 生成锁文件，gofmt 格式化源文件。仅导出公开代码/模板，不包含环境变量或凭据。回填标准文件后最终提交将再次按锁文件直接构建。

## 最终验证：通过

源码提交：72f061e3d51c7a045d0811bd79ae7fe2a33b06eb。
[最终 CI 36759279670](https://github.com/YufeiSun5/universal-hmi/actions/runs/36759279670)：4/4 jobs success。

| 平台 | 实际执行 | 结果 |
| --- | --- | --- |
| Ubuntu 24.04 / Go 1.24.7 | go test ./...、go vet ./...、go build | passed |
| Windows 2022 / Go 1.24.7 | go test ./...、go vet ./...、go build（exe） | passed |
| Ubuntu / Flutter 3.35.4 | 锁定依赖、flutter analyze、2 项 widget 测试、flutter build web --release | passed |
| Windows / Flutter 3.35.4 | 锁定依赖、flutter analyze、2 项 widget 测试、flutter build windows --release | passed |

以上是 GitHub Actions 虚拟机真实编译证据；当前会话云执行环境仍离线。Go HTTP/持久恢复测试与 Flutter fake API 的 widget 测试不是完整桌面到真实后端的联调，也不是现场验收。

实际产物：
- [go-server-linux](https://github.com/YufeiSun5/universal-hmi/actions/runs/36759279670/artifacts/11118112149)：5041226 bytes；sha256:dcabcb32665ecf7acbbea41161ade587041690064d1ba5d0dc55cc6747bd4266。
- [go-server-windows](https://github.com/YufeiSun5/universal-hmi/actions/runs/36759279670/artifacts/11117998267)：5055268 bytes；sha256:271f4d84dbaf4eae47f9aee9d2847f64515bc6517097c8c2e914168c63de15fc。
- [flutter-web-release](https://github.com/YufeiSun5/universal-hmi/actions/runs/36759279670/artifacts/11117728858)：10550460 bytes；sha256:ae593ddae788731578bf2d4a1a295dab711c76954af09ba2c0acdedc156a6226。
- [flutter-windows-release](https://github.com/YufeiSun5/universal-hmi/actions/runs/36759279670/artifacts/11117704183)：11600142 bytes；sha256:700e30979a225d13ef34d4cc652561dd9dbce852106a5d74c97bfb5b594721af。

仓库已包含标准 Windows/Web runner、图标模板和 pubspec.lock；直接构建，不依赖 CI 临时生成项目。源码/文档回读核对通过；25 项文档相对链接通过。SPT 采集/独立存储尚未迁入，条件脚本、图表和 Excel 功能仍按看板推进。

本次验收后仅提交文档状态与证据归档，不修改已验证源码；证据提交使用 [skip ci] 避免重跑同一源码。
