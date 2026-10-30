# 2026-10-26 Windows MQTT 临时测试包

用户要求输出临时 EXE，用于自行测试 MQTT 站点和数据绑定。本批只构建、组包和验证，未修改业务源码或现有运行工程。产物位于 `dist/Universal-HMI-MQTT-Trial-20261026/`，完整 ZIP 为同名 `.zip`；解压后启动 `universal_hmi.exe`，不能单独复制 EXE。包内 README.txt 提供来源配置、变量应用、连接、站点画面绑定与保存步骤。

Git 基点为 f552d81cece70a3bc7f4287b228e15bbdd6c2108，工作树源码 SHA256 为 `4b8294f0a48e05f666e4c3b9586e856e0e6093e2168b65c62458afe6d32924ba`。各文件摘要随 build-manifest.json 提供。工具链：Windows x64，Go 1.24.7、Flutter 3.35.4 / Dart 3.9.2。Web 输出在独立临时目录构建，未覆盖已有 18139/18153 服务资源。

远端核对：当前基点的完整 CI 38031925059 和生命周期 38031925060 均 success；早期交接的 36883999289 最终为 failure（Linux 组包启动验证失败）。这些 CI 均不覆盖本次未提交源码，以下为本次本地证据。

## 实际检查

- passed：go mod verify、go test -mod=readonly ./...、go vet -mod=readonly ./...、Go Windows build。
- passed：锁文件依赖恢复、flutter analyze、完整 155 项 Flutter 测试、Windows/Web release。源码摘要与两端产物来源一致。
- passed：包内 Go、Flutter、VC++ x64 可再分发运行库及离线 Web/GIS 资源齐全，文件清单校验。
- passed：从交付目录启动实际 EXE，原生窗口可见开发工作台、空站点和后端已连接；使用独立 LOCALAPPDATA，未加载用户已有工程。自动后端 health、点位/运行值/画面目录接口可读；Web 首页、main.dart.js、GIS map.html HTTP 字节与包内文件一致。
- passed：Alt+F4 关闭原生窗口，进程 exit=0。
- failed / 已说明：窗口退出后本包自有后端仍监听 18080。未借临时打包扩大为 Windows 生命周期实现改造；随包 Stop-Test-Backend.cmd/ps1 校验精确程序路径、拒绝在本包窗口仍运行时停止，仅清理该目录后端。该脚本已在隔离实例实际执行，18080 释放，数据保留。长期修复继续由 UX-02 跟踪。
- skipped：本机无 Mosquitto，两个 TestLocalKIO 集成测试明确跳过，不将 Go 总体通过称为真实 MQTT 联调通过。
- unexecuted：现场 Broker/真实设备、生产凭据、长期负载、DPI/多屏验收。原生 GIS 尚未内嵌，使用同包浏览器页面。

本轮第一次 HTTP smoke 使用了不存在的 GET /api/v1/sources，收到 404；修正测试脚本使用实际公开接口后通过，未修改/放宽应用路由。第一次组包引用不存在的仓库根 LICENSE，复制失败；移除该错误路径，继续保留包内字体、FUXA、GIS 等各自许可并重新核对组包。

完整构建日志、隔离数据、smoke-result.json 和最终 delivery.json 保留于 `.local/mqtt-trial-20261026/`。最终 ZIP 校验包含 CRC 及每个清单文件解压后 SHA256；分发摘要在 `dist/Universal-HMI-MQTT-Trial-20261026.sha256.txt`。包内不含现场凭据或用户已有工程。


## v2：Windows 内嵌 GIS 与工艺图（用户追加要求）

新包 `dist/Universal-HMI-MQTT-GIS-Trial-20261026-v2.zip` 替代上面的旧包建议入口。Windows 适配器使用 webview_windows 0.4.0 和 Edge WebView2；依赖 Windows 系统 WebView2 Runtime，本机已安装并通过实际窗口验证。不再只显示浏览器提示，工艺图仍复用既有编辑与呈现能力。

`01-Customer-GIS.cmd`、`02-Developer-MQTT.cmd`、`03-Customer-Process.cmd` 共用 `%LOCALAPPDATA%/universal-hmi-mqtt-gis-trial-20261026-v2`；首次复制三站占位点、一张无绑定工艺图和公共示意GIS。以后启动不覆盖已有目录，端口18080占用时拒绝启动，退出仅清理此启动PID所属且路径匹配的Go子进程。直接双击EXE仍使用通常工程，原生后台残留缺陷未借此宣称修复。

源码 SHA256：`8093d9e8d5fb799a581bda227b9465c846084405e4d1b57a7f64df74c30374b8`；Git仍为前述基点，旧CI不覆盖本次本地更改。完整日志、打包脚本、delivery.json 与 smoke-result.json 在 `.local/mqtt-trial-gis-20261026/`。

- passed：Go test/vet/build、Flutter analyze、完整157项测试；最后禁用原生地图缓存后10项针对回归通过，Windows/Web重新release构建。
- passed：原生启动进入GIS，点表初始化后保留GIS页面；地图、海面、六站显示及GIS/工艺菜单切换。发现全局GIS页面被站点会话恢复覆盖，已修复并增加自动回归。
- passed：在隔离验收工程通过公开API创建手工温度样本、应用配置，将GIS与工艺图引用保存。原生工艺图61.2→62.3连续刷新；重启后GIS浮窗显示62.30°C、已绑定1/5和有效数据1/1，未绑定项仍明确未绑定。此为手工样本链路，不是MQTT现场联调。
- passed：完整包HTTP首页/main.dart.js/map.html与文件字节相同，启动脚本关闭后自有后端退出，独立数据目录保留。
- passed：交付示例仍无point_id/bindings，不包含上述验收样本；当前Go二进制与包内backend_sha256一致。最终ZIP以CRC及每个文件SHA256核验，摘要见同名.sha256.txt。
- skipped / unexecuted：Mosquitto联调用例因本机无Broker程序跳过；真实站点、凭据、现场MQTT和跨机器WebView2/DPI仍未验。

中间故障已排除：并发Windows构建占用obj后串行重建；旧生成GIS目录脚本未包含读数，换当前源脚本后又发现WebView HTTP缓存混用，最终禁用缓存并版本化JS/CSS；一次增量复制误带旧桌面目录的Go服务器，启动smoke超时，已恢复本轮Go产物并校验摘要。失败的中间ZIP留在.local作为诊断，不是最终分发文件。


## v2 安装程序（用户要求安装包）

产物：`dist/installers/Universal-HMI-MQTT-GIS-20261026-v2-Setup.exe`，163,358,864 字节（约156 MiB），SHA256 `eb39fa9e5f5e76103c42f1cabc7e79f02a3ba0fa8765532eaa7d87c3ec9ad7b3`。这是前述来源 `8093d9e8…` 的冻结 v2 payload 安装封装，不混入其他并行任务随后修改的源码。安装程序未签名，供内部测试。

使用官方签名有效的 Inno Setup 6.7.3 编译器，沿用既有 packaging/windows.iss 的文件清单校验、当前用户安装、运行中拒绝更新/卸载规则；专用 AppId 避免覆盖常规产品。三个桌面/开始菜单快捷方式分别启动 GIS、工艺图、开发配置，均走已验证的 Start-Trial.ps1；安装过程不启动应用。按用户最新要求，不捆绑、不下载、不安装 WebView2，使用已有运行时，其他电脑缺少时独立安装。

- passed：安装EXE静默安装至隔离目录exit0，安装后6256个payload文件（含build-manifest.json）与冻结v2清单逐一匹配。
- passed：读取实际安装快捷方式的target/arguments/working directory，在隔离LOCALAPPDATA运行三入口；实际原生GIS、工艺图、开发工作台均可见。三个入口后端health和同包Web/GIS HTTP字节均核验；Alt+F4后启动器exit0、自有后端退出。
- passed：卸载exit0，安装目录、三个桌面快捷方式、开始菜单组和卸载注册项移除；隔离工程6个文件卸载前后摘要一致。
- unexecuted：无WebView2电脑、其他Windows机器、签名分发与现场MQTT；未重跑业务源码测试，沿用完全相同v2 payload已有结果。

详细证据和安装配方见 [installer verification](evidence/20261026-windows-installer/verification.json)。本轮一次工艺入口预检因前次后端退出未完成明确拒绝；等待GIS smoke完整退出后重试通过，没有接管已有服务。
