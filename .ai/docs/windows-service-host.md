# 可选 Windows 无人值守宿主

产品母本：[agent.md](../../agent.md)。本功能属于部署生命周期；采集、权限、存储和公网 HTTPS 仍由同一个 Go 后端公开契约提供。客户端不拥有此服务的生命周期。

`backend/cmd/service-host` 是真正实现 Windows SCM 协议的宿主，依赖已有 `golang.org/x/sys/windows/svc`，不是将普通 server.exe 直接注册成服务。Linux 构建提供明确不支持的入口。`internal/desktopservice` 独立测试启动/退出编排，Windows 命名事件仅作为本次子进程的本机停止信号。

先通过既有离线入口初始化专用工程和数据库；本宿主不会初始化、迁移或下载 PostgreSQL。可选安装脚本 `packaging/Install-ProjectService.ps1` 要求管理员，指定 ServiceBundleRoot、ServiceHost、ProjectConfig、PostgresBin、PostgresData；默认只注册自动启动服务，不在本次安装立即启动，显式 `-Start` 才请求启动。使用 LocalService，无新系统账号和明文账号密码。配置文件 `service-host.json` 含 `projectConfig`、`postgresBin`、`postgresData`，相对路径以该文件目录解析；project.json 必须完整持有 app/server/data/web/databaseConfig/port 和可选 remoteConfig。普通启动器发现同工程 service-host.json 后只连接服务，不自行启动PG/后端；服务未就绪须检查管理员配置与服务日志。

必须使用本地、用户 profile 外的独立 ServiceBundleRoot，全部宿主/后端/桌面程序、Web、PG二进制与工程路径须在其内。工程是单独子目录，data、databaseConfig、remoteConfig 和 PostgreSQL 数据在工程子目录；程序资源不得位于服务可修改的工程子目录。安装脚本只调整此明确指定bundle的ACL，保留安装操作者和管理员/SYSTEM 完全访问，LocalService默认读取执行，仅工程子目录允许修改；不修改外部共享程序或PG目录。根目录及关键路径逐级拒绝祖先reparse，整个bundle拒绝junction/symlink。执行宿主前后核对关键EXE/DLL/PS1/JSON的所有者和ACL，拒绝普通Users、Everyone、Authenticated Users等其他主体写入；父目录不得授予其他主体删除/改权限/夺取所有权。初始包若权限过宽会直接拒绝，需先由管理员在专用位置准备受保护副本。其他本机操作人员访问须现场明确配置。数据库凭据沿用已经配置的 databaseConfig，不新建副本。

启动拒绝后端端口、数据库端口已被占用，拒绝已有 postmaster.pid 或运行中的目标 PostgreSQL；不接管已有服务。PG 仅回环监听，启动后经已有 DSN 实际查询 `SHOW data_directory` 核对目标，再启动后端。后端原参数和 remote-config 合同保持；SCM Running 表示子进程已创建，工程认证、HTTPS和业务就绪仍需检查部署端点及日志。

停止/系统关闭触发本次随机 Global 命名事件，后端通过现有 context 优雅退出。45 秒未退出时宿主明确记录失败，不强制杀进程，不停止仍可能被后端使用的 PG。正常退出后才用 pg_ctl fast 停止本次启动且 postmaster PID 未变化的集群。意外掉电/系统强制终止、PG启动部分成功但无法核验身份、异常停止后遗留进程均需检查日志和 PostgreSQL恢复状态；不会自动接管或删除 PID 文件。移除脚本停止并删除匹配服务宿主的注册项，保留所有工程/数据库文件与 ACL。

服务宿主子任务未安装、未启动真实 SCM 服务，未改防火墙或路由；主代理另行升级本机18153应用，见[公网与远程验收](public-remote-verification.md)。模拟测试覆盖预检查失败、PG启动失败、后端启动失败、正常退出与后端停止失败保留PG；`packaging/tests/Test-ServiceInstaller.ps1` 用模拟ACL/路径元数据验证普通主体写拒绝、服务写范围、恶意owner、祖先junction和同前缀路径逃逸。Go Windows测试/编译及vet、Linux stub编译和脚本语法/模拟策略检查通过，不能作为开机无人登录、真实PG或现场ACL验收证据。
