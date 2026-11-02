# Dot 拉取版验证与 Windows 完整包 v20

2026-11-02，用户要求先测试拉取的版本，再制作最新完整安装包，保留现有工程和数据。用户已追加完整安全实现要求，本次发行暂停交付，以下仅为追加要求前的验证记录；后续实现后必须重测重建。

范围仅为发行模块：`ci/build_windows_lazy.py`、`packaging/windows-lazy/windows-lazy.iss`、`packaging/windows-lazy/INSTALL.txt` 更新版本号、产物名称和说明；业务代码沿用 main `0ee59d2383e36cb615728eeb82a6bde0a17aa249`。旧 `codex/process-canvas` 分支与历史安装包保留。未自动合入 `feat/device-certificate-channel` 实验分支。

## 追加安全范围后的当前进展

设备传输/绑定/撤销、真实Coraza请求侧CRS、持久封禁与本机UI已实现；Go1.27.3全test/vet、修改后server/publicguard/identity专项、缓存完整校验通过。Flutter461通过、2浏览器专用跳过、analyze无问题；Android5项JVM测试及签名release构建通过，APK v2签名证书SHA256 `97247b52d1b26718619999c4c7fd4b308b8f50418079b954ba1e6faa132cf80c`。许可证组装已可重复生成，Windows/Web/完整EXE与隔离升级仍在进行。之前的构建摘要不是新安全代码证据。真机、公网、旧全库备份授权对账尚未验收。

## 追加前的历史验证

| 检查 | 当前本地结果 |
| --- | --- |
| 固定工具链 | Go 1.24.7、Flutter 3.35.4 / Dart 3.9.2、Python 3.12.13、Inno Setup 6.7.3 |
| Go | `go mod verify`、`gofmt -l`、`go test -mod=readonly ./...`、`go vet -mod=readonly ./...` 通过 |
| PostgreSQL | 独立模拟工程的 PG 18.6 上，persistence / identity 实际数据库集成测试通过 |
| Flutter | 188 文件格式检查无变更；`flutter analyze --no-pub` 通过；457 项测试通过、2 项浏览器专用用例跳过 |
| Windows 安装辅助契约 | public config 4 项；native window 2 项通过、2 项其他平台编译跳过；CRT 16 项；维护工具防护 12 项；远程启动器 2 项通过 |
| HTTP | 使用本轮新编译的 Go EXE，11 项独立临时数据回归通过 |
| KP 脚本 | 18 项会话 / 登录 / 退出 / 重试模拟通过，不连接真实设备 |
| 字体 | `python ci/prepare_fonts.py --check` 通过，使用已固定的本机离线字体 |

拉取源码的 [Verify CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/41338422957) 已核对 10 个 job 成功；macOS 打包在重跑后成功。这是 main `0ee59d2` 的上游结果，不冒充本次发行元数据提交的新 CI。本机 CGO=0，未运行 Go race；真实 MQTT、浏览器专用单测、完整 Windows 原生人工操作和多 DPI、真实公网/NAT 未在本轮执行。

执行记录：`.local/release-20261102-v20/`。最初误将 Linux 专用打包 fixture 纳入 Windows 的整目录 unittest 扫描，该扫描失败并已停止，不计为通过；随后按 CI 平台划分执行上述适用项。首次真实 PG 测试被仍运行的模拟后端租约拒绝；停止该模拟后端、单独启动其 PG 后重跑通过，保留单实例防护。

## 构建与保留升级

全新 Windows 与 Web 输出的源码摘要均为 `aca4b52e9c5a273b8cf1644e1f6121dd21a7306be203e5636e9b946af84e710e`。Go 后端 SHA256 为 `3a023b64a1339957521be440978d675a46818a6e7903f822f7365de4f2ee8e0c`。完整发行目录计划为 `dist/Universal-HMI-Dot-v20-20261102`，内含 Windows、Go、Web、离线 GIS、app-local VC++ runtime、手动导入资料，再由安装器合入固定摘要的 PG 18.6。

Windows / Web 编译成功，存在非失败的既有构建提示：NuGet 未安装、webview_windows 的 CMake CMP0175 开发警告、CupertinoIcons 字体引用提示。未为消除提示修改业务或第三方插件。

完整安装器尚未产出：fresh bundle 缺少旧封装流程手工附带的 licenses 目录，组装已失败关闭，需补齐可重复封装步骤；此失败未被计为通过。追加安全实现前，已卸载隔离v19程序，保留模拟工程并恢复快捷方式。v19→v20升级、重复安装和卸载新版本的验收尚未执行。隔离测试目录为 `.local/full-v20-installer-verification`，从已停机的 v19 模拟工程复制，使用 `18184/55436`；旧测试 HTTP 端口 18084 落入本机 Windows 保留范围，未更改系统保留设置。基线为 5,019 点、31 图、11 张业务表及设备照片。新建空工程与 SQLite 迁移的专项结果待验。

本轮不升级、重启或刷新实际 18153 入口；不连接或控制现场，不修改公网、防火墙、路由、系统服务与系统证书信任。不将测试账号、模拟工程或数据库放进安装包。安装器保持原 AppId，`preserve-only`，没有重建页，不调用工程重建工具。

## 使用边界

本包是 Windows x64 完整安装 EXE，包含私有 PG，不是安卓包。公网默认关闭，IP 留空；已合入公网只读边界、IP 白名单管理、审计与设备登记。安卓、设备证书访问通道和 WAF 正式接入仍未完成，设备登记本身不授予移动端访问权限。

覆盖安装使用原 Windows 账号及原安装目录。先从托盘分别退出开发端和用户端，再从开始菜单停止后台；无需卸载，无需重新导入、扫描或删除变量。开发及管理仅本机，公网连接仅供查看。安装器未签名；WebView2 是外部运行时前提，安装器不下载或安装它。

相关契约：[架构](architecture.md)、[验证要求](verification.md)、[此前 v19](gis-zones-v19.md)。
