# 通用临时上位机平台 · Universal HMI

Go 后端 + Flutter 桌面/Web 的多站采集、受控写入、事件、独立历史存储与数据分析工具。界面采用蓝灰浅色桌面工作空间：公共总调度负责跨站查看；每站拥有运行总览、变量监视、历史报表、历史曲线和设置。

本轮功能版本已通过 Linux/Windows/Web 完整 CI 和 Linux 快速关闭专项，并合入 main；仍不宣称已通过生产现场验收。本地最终 tar 的原生文件流、正常退出和同包 Web 文件流也已通过。工程从公开基底 `7cafe7c5a6597c72d71fdf9694370c2fc5db6333` 重新实施；不是此前未保留源码的逐字恢复。最新结果、候选包身份和剩余门禁见 [阶段记录](.ai/docs/v0.1.md)。历史 CI/下载不代表当前版本。

## 当前能力与验证边界

- 默认虚拟化变量矩阵，可切换表格和紧凑/舒适密度；质量文字/图标、数值、单位和读写状态同屏展示，站点切换保留各自筛选/选中/趋势状态
- 5 个真实本地 Mosquitto、30 站×500 点、15,000 变量的原生持续 profile 已验证；最新 `cb98d1b` 同源 CI 达到 120.030 秒、22 项检查通过、3,150,003 累计样本接受/处理一致且零 drop
- 上述百万样本计数表示采集处理链路，**不表示每个样本都已持久化到历史库**；存储按各自启用的周期/变化/快照策略运行
- generic、Kepware values、KingIO `Objs/PVs` 读取；缩放偏移、手工/虚拟点、声明式条件事件；受控 generic/KIO 写入将发送、ACK 和后续新鲜物理读回分开
- 站点独立存储策略/事件作用域；SQLite 冻结历史语义；CSV/XLSX 映射、筛选、统计和有界导出任务
- 最终产品 head `cb98d1b` 的完整 CI 与关闭专项通过；专项含自有后端窗口关闭和 10 次快速复用窗口关闭，均 exit 0；保留最终帧提交、视图分离、同帧光栅完成和 engine dispose 的顺序证据

真实 Linux 原生矩阵截图已在交付报告和会话中提供。

已交付截图来自实际 Linux 原生窗口和本地 KIO/MQTT fixture，不表示生产设备数据。界面与质量验收范围见 [桌面体验](.ai/docs/desktop-experience.md)。

## 运行桌面候选包

已验证产品版本 `cb98d1b`，产品合并提交 `d7f267a`：

- [下载 Linux x64 完整包](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975726752/artifacts/11213454482)
- [下载 Windows x64 完整包](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975726752/artifacts/11213672430)
- [完整 CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975726752) / [Linux 关闭专项](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975726754)

下载需要登录 GitHub；这两个 artifact 过期时间为 2026-12-31 06:53:17 UTC。运行前核对包内来源记录与 SHA256SUMS；不要沿用历史版本摘要。更多证据见 [阶段记录](.ai/docs/v0.1.md)。

- Linux x64：解开 artifact ZIP（若有），再解开其中 tar.gz；进入 `universal-hmi`，运行 `./universal_hmi`，保留完整目录。Linux CI 目标为 Ubuntu 24.04，需要 GTK 3、EGL/GL 与对应运行库
- Windows x64：在完整目录运行 `universal_hmi.exe`；Windows 编译结果与真机窗口/文件/DPI/生命周期人工验收分别记录
- 桌面启动包内 Go，或复用兼容的本机后端；浏览器访问 `http://127.0.0.1:18080`，共享该后端的数据。正常退出只关闭本窗口拥有的 sidecar
- Linux 数据目录：`$XDG_DATA_HOME/universal-hmi`，默认 `~/.local/share/universal-hmi`；Windows：`%LOCALAPPDATA%/universal-hmi`

先使用明确标记的模拟工程（30 站/90 点）熟悉保存、应用、采集、快照和报表流程；它与 15,000 点容量 fixture 是不同用例。点位保存后须显式应用运行版，来源保存后须显式连接，独立存储也需明确启用或创建快照。

## 从源码开发

固定版本：**Go 1.24.7、Flutter 3.35.4 / Dart 3.9.2**。从官方 SDK 获取匹配版本并加入 PATH；保留 `go.sum`、`pubspec.lock` 和已提交的 Linux/Windows/Web runner。Linux 不能代替 Windows 上的 Flutter Windows 构建。

Linux 开发依赖 clang、cmake、ninja-build、pkg-config、GTK 3 开发库、EGL/GL 和 liblzma；自动测试额外使用本地 Mosquitto、Xvfb、xdotool/ImageMagick、Playwright 1.55.0。完整环境与验证步骤见 [verification.md](.ai/docs/verification.md)。

### 1. 准备锁定的离线字体

在仓库根目录运行，建议使用独立 Python 虚拟环境：

~~~sh
python -m pip install -r ci/requirements-fonts.txt
python ci/prepare_fonts.py
python ci/prepare_fonts.py --check
~~~

配方 [fonts.lock.json](ci/fonts.lock.json) 固定官方字体来源、输入/输出 SHA-256 和工具版本，生成 `app/assets/fonts` 内的字体。应用运行使用包内字体，无需在线字体服务；首次重建配方需要访问锁定来源。不要从无关下载站替换字体或跳过校验。

### 2. 启动开发后端与 Linux 客户端

两个终端分别执行：

~~~sh
cd backend
go run ./cmd/server --data-dir .local
~~~

~~~sh
cd app
flutter pub get --enforce-lockfile
flutter run --no-pub -d linux
~~~

浏览器开发可给 Go 增加 `--dev-origin http://localhost:5173`，在 app 执行 `flutter run --no-pub -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://127.0.0.1:18080`。正式同源 Web 使用已构建的 `app/build/web`；默认本机回环监听，开发 CORS 不是远程鉴权。

### 3. 检查并串行构建 Linux 包

先运行 [完整只读门禁与原生 profile](.ai/docs/verification.md)，确认通过后从仓库根目录执行：

~~~sh
mkdir -p dist
(cd backend && go build -mod=readonly -o ../dist/universal-hmi-server ./cmd/server)
python ci/build_release.py linux
python ci/build_release.py web
python ci/package_desktop.py linux
python ci/package_final.py --targets linux --stage-local
~~~

输出为 `dist/final/universal-hmi-linux-x64.tar.gz` 和 `SHA256SUMS`。`--stage-local` 从本轮已验证 build 更新 staging；构建/组包会核对来源清单、官方 release engine、AOT 和产物摘要。不要并行执行 native debug/profile/release，它们共享 ephemeral 目录。组包成功之后还必须从实际 tar 解包验证新界面、正常关闭和包内 Web 文件流。

## 范围与限制

当前是一个本地后端下的逻辑站点项目与公共调度。站点独立状态/规则/存储不是账号权限、独立数据库或操作系统级项目隔离。服务只允许本机回环访问；远程认证、部署、生产凭据、备份/升级回滚和长期现场负载仍需专项工作。

真实设备尚未验收；Windows 真机人工操作、DPI/多屏与文件对话框，以及用户可操作的 cloud-browser 交互预览仍未验。隔离 Chromium 自动文件回归通过不能替代这些证据。KIO 写入的协议/超时/去重/ACK/读回测试使用本地合成网关，不能声称任意厂商版本兼容。generic `sent` 仅代表 broker 收到。

点位发现、完整多工程权限隔离、历史全区间降采样、游标与表格双向联动、复杂 Excel 模板等仍是后续目标。脚本仅支持受限公式和声明式事件，不运行任意系统代码。SPT 通用能力经过参考审阅，检测业务没有迁入，不能称为全量后端迁移。

## 项目文档

- [阶段结果与证据](.ai/docs/v0.1.md)、[桌面体验](.ai/docs/desktop-experience.md)、[验证方法](.ai/docs/verification.md)
- [架构合同](.ai/docs/architecture.md)、[接入合同](.ai/docs/protocols.md)
- [产品要求母本](agent.md)、[编码入口](AGENTS.md)、[当前工作看板](AI_BOARD.md)
- [初始化记录](.ai/docs/initialization.md) 与 [历史交接](HANDOFF.md)

仓库公开可见，项目开源许可证尚未选择；字体与后续引入代码保留各自来源及许可证。初始化参考 [dotai-scaffold](https://github.com/YufeiSun5/dotai-scaffold)。
