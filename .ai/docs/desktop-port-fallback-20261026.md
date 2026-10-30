# Windows 桌面端口自动回退验证（2026-10-26）

用户反馈客户端 18080 被其他程序占用，要求自动换到可用端口；不涉及 MQTT broker 1883。

## 实现与边界

- `backend/cmd/server/desktop_listener.go`：桌面 `--auto-port` 优先绑定 127.0.0.1:18080，失败后由系统分配端口；同一监听器持续持有。固定端口部署仍按原配置失败，不静默改变远程认证/TLS/KP 的地址。
- `--endpoint-file` 在本次启动临时目录原子发布 URL/PID；Flutter 校验字节上限、本次子进程 PID、HTTP、127.0.0.1、端口及无额外路径/凭据/查询后检查健康。
- `app/lib/platform/backend_endpoint.dart` 统一 API、SSE、文件与 Windows GIS 的实际服务地址。Web 同源、显式 API_BASE_URL 和已有健康 HMI 服务复用保持。
- v3 启动脚本移除端口被占用就退出的限制；沿用 `%LOCALAPPDATA%/universal-hmi-mqtt-gis-trial-20261026-v2`，首次示例复制不覆盖已有配置。
- WebView2 按用户要求独立安装，不内置、不下载。未新增生产设备访问或业务写入。

## 来源及自动检查

Git 基点 `f552d81cece70a3bc7f4287b228e15bbdd6c2108`，本批为未提交工作树；Windows/Web 来源摘要 `e3c2f11885cf6edeb8915a7c4ab8e40bd9e4a3c6d65a1eede30b89dfbba8190f`。

基点 CI 38031925059、38031925060 查询均 success，仅代表基点，不覆盖本批未提交修改。

通过：Go `go test ./...`、`go vet ./...`；Flutter analyze、162 项完整测试；Windows/Web release。新用例覆盖被占用端口回退、选定端口持续保留、空闲首选端口、禁止非回环回退，以及旧 PID/不合法地址拒绝和 API/GIS 同地址。初次 analyze 提示缺少大括号，修正后完整检查通过。

## 安装与真机验收

已执行并通过：

- 隔离目录实际安装 v2，再用相同 AppId 覆盖安装 v3，逐文件校验全部 6256 个文件；预置 v2 工程与保留标记逐字节保持。
- 读取安装后真实快捷方式的目标/参数运行 GIS。测试 HTTP 服务占住 18080，后端实际选择 26810，健康检查、画面列表、同包 Web/脚本/GIS 字节核验通过；Windows 原生窗口实际显示庄河地图，切换工艺图成功。
- Alt+F4 正常关闭返回 0，自有 26810 后端停止，18080 上原测试服务仍正常响应；之后只由 fixture 自行释放它的监听器。
- 空闲场景从工艺图快捷方式启动，实际使用 18080；工艺图、公开接口与同包资源通过，正常关闭返回 0 并停止自有后端。
- 卸载隔离安装目录成功，安装文件移除，7 个用户数据文件的摘要保持。测试未接触用户工程。

产物：`dist/installers/Universal-HMI-MQTT-GIS-20261026-v3-Setup.exe`，163263643 字节，SHA-256 `aae6e010427365b4767c28c1880e759a8c9c665d53f92a784aa5e03c3452bf4f`。保留旧 v2 安装包；新安装器版本 0.1.0.2。未签名内部测试版。

详细结果与配方快照见 [verification.json](evidence/20261026-desktop-port-fallback/verification.json)。真实现场 MQTT、设备写入和长期运行未执行；既有 Mosquitto 专项因本机无 broker 工具跳过，不能称为现场联调通过。
