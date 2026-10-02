# 三平台安装与同包 Web

本轮目标：Windows x64、Linux x64、macOS Intel/Apple Silicon 通用安装包，全部携带 Go 后端与离线 Flutter Web。实际完成和失败以当前提交的 CI 与安装证据为准；下面的设计/命令不代表已完成原生人工验收。

## 边界与默认行为

安装器只管理应用文件，不创建账号、证书、自动启动项、系统服务、端口转发或防火墙规则。不连接生产 MQTT。桌面启动后默认仅服务 `http://127.0.0.1:18080`；同一台电脑上的浏览器可打开该地址。默认没有局域网或公网发布。

桌面自启动的后端归该桌面所有，正常关闭桌面会关闭该后端。浏览器退出不影响后端。需要持续后台服务时由操作者独立启动包内后端，桌面可复用兼容本机服务且不终止它；不要同时启动两份共享数据库的后端。

Web 的局域网发布能力依赖包内同一个后端，必须显式配置用户拥有的账号、受信任 TLS、精确 HTTPS origin 与监听地址。合同与命令见 [内网认证](intranet-auth.md)。安装包不带默认密码或证书，不自动信任自签名证书，不启用 MCP 写入。提供能力不等于已完成真实网络部署。

## 文件布局与数据

- Linux：`.deb` 面向 Ubuntu 24.04 x64，应用在 `/opt/universal-hmi`，入口 `/usr/bin/universal-hmi`；另有无需管理员权限的 `.install.pyz`，执行 `python3 universal-hmi-linux-x64.install.pyz --prefix /绝对/安装路径`。根目录生成 `launch-universal-hmi` 与 `uninstall-universal-hmi`；同一安装命令更新应用
- Windows：Inno Setup `.exe`，按当前用户安装，无需自动提权；应用版本目录与个人数据分离，开始菜单入口与标准卸载项由安装器管理
- macOS：11 Big Sur 或更新（[Go 官方最低版本](https://go.dev/doc/go1.23#darwin)；旧系统未进行人工验收），`.dmg` 内 `Universal HMI.app`，复制到用户有权写入的 Applications 目录后运行；应用采用 Intel x86_64 与 Apple Silicon arm64 通用二进制。Web 位于 `Contents/Resources/web`，后端位于 `Contents/MacOS/universal-hmi-server`
- 个人数据：Linux `$XDG_DATA_HOME/universal-hmi`（缺省 `~/.local/share/universal-hmi`）；Windows `%LOCALAPPDATA%/universal-hmi`；macOS `~/Library/Application Support/universal-hmi`
- 更新/卸载必须先正常关闭本应用和包内后端；卸载不清除个人工程、历史库、导出或操作者账号文件。删除这些个人数据属于另一个明确操作

本轮无商业代码签名证书或 Apple 公证。Windows SmartScreen 与 macOS Gatekeeper 可能提示来源未验证或阻止打开；检查来源和 SHA-256，并遵循操作系统提供的用户确认流程。不得通过关闭系统安全功能或移除安全属性来冒充可安装性。Linux 本地构建/自动化证据不能替代 Windows/macOS 真机人工测试。

## 可重建门禁

1. 固定 Go 1.24.7、Flutter 3.35.4、锁定字体与依赖；各桌面原生 runner 独立构建
2. `ci/build_release.py TARGET` 记录源码和构建产物 SHA-256；`ci/package_desktop.py TARGET` 加入后端
3. `ci/package_final.py --targets TARGET` 要求桌面与 Web 的源码身份一致，检查所有产物后加入 Web
4. `ci/build_installers.py TARGET --expected-revision SHA` 验证完整包后生成原生安装器及摘要
5. `ci/installer_smoke.py TARGET` 在对应原生 CI 中隔离安装、启动已安装后端、逐字核对服务出的 Web、更新及卸载，并检查外部用户文件保留
6. Linux 另跑最终包原生窗口正常关闭和十次复用关闭；人工截图由实际桌面和浏览器操作采集。自动安装检查与人工 OS/DPI/多屏验收分别报告

不发布 GitHub Release，不上传任何客户数据或真实凭据。CI artifact 是测试分发产物，不意味着已签名发行。

## 本轮已执行的后台回归（基线 656011b）

[可审查摘要](evidence/20261002-installers/backend-qa.json) 与 [逐次负载观察](evidence/20261002-installers/capacity-soak.json)：120 个 Go 顶层测试通过（含子测试272；跳过一个明确 opt-in 的人工 CUA fixture），vet/mod verify 通过。44 个故障/换算/事件相关测试重复十轮，共440次顶层执行通过。另加七个真实进程 HTTP 契约测试，涵盖20000边界、75000原子拒绝、崩溃/WAL恢复、不重放写入/规则、配置版本/换算冻结、历史分页与 MCP/网络门禁。

五个本地 MQTT broker 分担总共30站，每站500点，合计15000点；不是每个 broker 都有30站。约98.366秒（包含90次1Hz观察及暂停/恢复）共接收并处理1410003样本，0drop，暂停后15000点全部stale、恢复后全部good。定时存储站42500历史行，条件快照站1000行。runtime API延迟中位68.75ms、P95 126.3ms，后端RSS94.1–125.0MiB；这些是该机器短时合成负载，不是60FPS、长期负载或真实设备验收。

这批后台源码未改动；安装器/平台代码仍需自己的精确提交 CI 和最终产物验证。

### 05b405c 本地实际安装检查点

从独立干净 worktree 串行构建 Linux 与 Web，来源摘要均为 `05cd30f4bacc6a42d9132d648e2a65794978e95dfe5e16d59b90fc6538d90970`；Go 二进制记录 `vcs.revision=05b405c...`、`vcs.modified=false`。实际 `.deb` SHA-256 为 `93b08cdb73e10b98a99a214315e3dc0fb577da7d9a77a48bcc9ab7624203fbc2`，rootless安装器为 `e664ea8e655f348470bd59cdb5211d7208304da2bdb92f1db37d78bf1518ea16`。安装→启动已安装后端→逐字核对Web→更新→卸载/保留外部用户数据均通过；随后另行安装并经实际桌面操作打开，使用内置30站90变量演示，保持运行。

本地 dot 云浏览器尝试该回环地址返回 `ERR_BLOCKED_BY_CLIENT`，因此不能声称已在该浏览器看到 Web。已安装服务的实际 Web HTTP 字节校验与浏览器可访问性分别报告；没有使用安全绕过、转发代理或公网暴露解决此限制。CI 浏览器证据仍需对应本轮运行通过。

首轮三平台 CI [37027920523](https://github.com/YufeiSun5/universal-hmi/actions/runs/37027920523) 的 Linux/Windows 后端通过，Mac ARM64 因现有倍率/偏移回归失败而停止；后续修复与最终产物以新 head 为准，不能将这个检查点称为三平台完成。

### ARM64 与干净 Windows 运行时修复

提交 `10850ef` 将倍率/偏移统一为显式两步 float64 运算，保留全部原有误写拒绝断言；[局部回归及编译器证据摘要](evidence/20261002-installers/arm64-rounding.json)。`d50ecf1` 补充官方已安装 Visual Studio 的 app-local VC++ release DLL，并记录和检查 x64 PE 架构及全部摘要，防止仅在安装了开发工具的 CI 机器可运行。

新 [CI 37029546718](https://github.com/YufeiSun5/universal-hmi/actions/runs/37029546718) 已在原生 macOS ARM64 通过 Go race 全套、vet 与后端编译，Linux/Windows 后端也通过。其后 macOS `lipo -verify_arch` 参数顺序不符合原生命令而失败；修正为先输入文件、后架构验证参数。此记录不将被跳过的 Flutter/安装器任务计为通过。
