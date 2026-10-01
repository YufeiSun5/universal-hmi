# 通用临时上位机平台 · Universal HMI

Go + Flutter 的通用采集、控制与分析软件。PC 优先，桌面发行包同时包含本机浏览器界面；采用紧凑工作空间、点位表、图表与属性面板。

第一版核心实现了多站 MQTT 映射、手工/虚拟点、缩放偏移、受控下设、AND/OR 条件事件、独立 SQLite 存储、历史筛选统计、CSV/XLSX 导入映射和报表任务。已通过的测试、实际截图和下载入口见 [第一版评审记录](.ai/docs/v0.1.md)。当前按用户要求移交 Dot 收尾；接手步骤见 [HANDOFF.md](HANDOFF.md)。SPT 的通用能力经过参考审阅，检测业务没有迁入；不能将本版称为 SPT 全量后端迁移。

## 下载和运行

从评审记录所链接的 GitHub Actions 运行页面下载 **universal-hmi-linux** 或 **universal-hmi-windows**，需要登录 GitHub。

- Linux：解开 artifact ZIP，再解开其中 tar.gz，进入 universal-hmi 目录运行 ./universal_hmi。首版 Linux 目标环境为 Ubuntu 24.04 x64 桌面，需要 GTK 3；请保留整个目录。
- Windows：解开 ZIP，在完整目录中运行 universal_hmi.exe。首版 x64 构建已通过，Windows 人工文件/窗口/DPI 验收仍待执行。
- 桌面自动启动包内 Go 服务；浏览器访问 http://127.0.0.1:18080，共用同一份数据。可复用已经启动的本机后端。
- Linux 数据目录为 $XDG_DATA_HOME/universal-hmi，默认 ~/.local/share/universal-hmi；Windows 为 %LOCALAPPDATA%/universal-hmi。

打开“启动模拟工程”即可添加 30 站 / 90 点。选择点位查看属性和趋势，给模拟设定点下设数值；启用独立存储或保存快照后，在历史/分析页筛选并导出。来源配置保存后需要明确点击连接。

## 第一版范围

现在提供一个本地工程下的多个站点；同一 MQTT 来源按稳定源路径映射到不同站点。多个独立工程的权限、目录隔离和工程切换尚未实现。点位自动发现、批量工程导入、历史全范围降采样、游标与表格联动、复杂 Excel 模板与排序属于后续目标。

Kepware values、KingIO Objs 和 generic 的读取格式见 [接入合同](.ai/docs/protocols.md)。物理写入当前只有 generic 命令合同，sent 表示 MQTT broker 确认收到；厂商下设、设备 ACK 与现场读回需协议样例验证。条件脚本是受限公式与声明式事件动作，不运行任意系统代码。

当前服务只监听回环地址。本机浏览器可访问，局域网远程访问需要后续认证部署。30 站演示及本地 Mosquitto 流程不等于现场容量或 PLC 验收。

## 开发

工具链固定为 Go 1.24.7、Flutter 3.35.4 / Dart 3.9。Linux 开发调试，Windows 在 Windows CI 构建；Linux 不能直接完成 Flutter Windows 本机构建。

先在 backend/ 启动开发后端：

~~~sh
go run ./cmd/server --data-dir .local
~~~

在 app/ 启动客户端：

~~~sh
flutter pub get --enforce-lockfile
flutter run -d linux
~~~

浏览器开发使用固定端口：Go 加 --dev-origin http://localhost:5173；Flutter 使用 flutter run -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://127.0.0.1:18080，以浏览器实际 origin 为准。生产 Web 构建后，可在 backend/ 运行 go run ./cmd/server --web-dir ../app/build/web。

## 项目入口

- [agent.md](agent.md)：用户指定的产品要求与长期约束母本。
- [AGENTS.md](AGENTS.md)：编码工具入口。
- [架构合同](.ai/docs/architecture.md)、[桌面体验](.ai/docs/desktop-experience.md)、[验证方法](.ai/docs/verification.md)。
- [MEMORY.md](MEMORY.md) 与 [AI_BOARD.md](AI_BOARD.md)：当前摘要及唯一活跃看板。
- [初始化记录](.ai/docs/initialization.md)：历史骨架验收。

提示词初始化采用 [dotai-scaffold 中文项目设计提示词](https://github.com/YufeiSun5/dotai-scaffold/blob/main/prompt-zh.txt)，源 blob d34a84e7ad485c726274a92c9f798c3bdf61a886。public 是仓库可见性，开源许可证尚未选择；后续迁入代码保留来源及许可证。
