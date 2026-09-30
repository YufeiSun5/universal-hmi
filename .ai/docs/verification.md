# 验证与发布条件

母本：[架构](architecture.md)、[桌面体验](desktop-experience.md)。

## 验证层次

1. 文档：本地相对链接、母本唯一性、约束计划位置、现状/目标区分与活跃看板。
2. Go：点位校验、保存恢复、HTTP 契约；后续规则、控制状态及协议适配独立测试。
3. Flutter：analyze、widget 交互；桌面与 Web 分别构建，编译不能替代人工交互。
4. 模拟集成：Go→UI 点位添加/刷新；规范化样本→事件→受控模拟写入/存储→文件重读。
5. 真实环境：批准的设备/协议、断线及确认，测试数据和生产事实分离。
6. 发布：版本、工具链、测试与构建日志、平台/环境及未决风险；现场缺证据不宣称生产通过。

## 工程骨架命令

Go 模块内：
```sh
go test ./...
go vet ./...
go build ./cmd/server
```

Flutter app/ 内（仓库包含 Windows/Web 标准 runner 和依赖锁）：
```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build web --release
flutter build windows --release
```

Windows build 需要 Windows + Visual Studio C++ 桌面工具链。Linux 虚拟环境可验证 Go/Web；不能据此宣称 Windows 通过。CI 应分 Ubuntu Go/Web 和 Windows desktop 验证，并保存真实日志/构建产物。缺 SDK/执行环境计 blocked。

## 核心门禁

- 用户添加点位后保存持久，重启读取保持；不谎报已建立采集连接。
- 来源/站点身份不会串读串写；缩放偏移与可逆 codec 按质量/版本生效。
- 条件重复、抖动、缺失、陈旧、恢复及循环依赖都有明确结果。
- 下设 ACK、读回、未知和部分成功区分，未知不自动重放。
- 独立存储无需检测；断库、队列满、重启和历史冻结语义单独验证。
- Excel 导入预览映射，筛选统计与导出重读一致；大文件有界处理。
- Web 认证/跨域/实时重连与桌面系统交互分别验收。

记录格式：用例、提交、工具链/环境、预期、实际、日志或产物、passed/failed/unexecuted/blocked。既有 SPT 测试不能代替新平台迁移后的验证。
