# v75 全终端实时订阅与手机报表交付

2026-11-11，本地 Windows/Web/安卓交付。应用源码 `437d4376e8ebb45085534814e46df132e1bc2fba`；应用源码摘要 `4d9a884f678f683a71fe1463b6e5cc4880face1a6cf843154dc9451cf40aef3e`。未部署现场、未修改18153或现场数据库。

## 实现

- 原 SSE 实时调用统一在共享 API 层迁移，覆盖 Windows、Web、KP、安卓及手机浏览器的 GIS、工艺画面、总览等订阅。新客户端使用二进制 gRPC-Web，Go 同时提供 HTTP/2 gRPC；不是把 HTTP/1 SSE 改名。protobuf 定义和生成代码随仓库保存。
- 保留旧 SSE 全量/增量和普通 HTTP 接口。新旧订阅共用增量生产逻辑，维持500ms周期、reset/epoch/sequence/version、权限撤销、质量和有效零。未改变 MQTT、历史存储、控制服务和认证策略。
- 每次重连核对健康服务器能力；旧版服务器无 RPC 能力时使用旧 SSE，认证、网络或 RPC 错误不作为降级理由。受控只读 POST 复用 Cookie CSRF、Bearer、KP、设备准入及站点裁剪；WAF仅对精确RPC路径的有界二进制正文使用protobuf验证。
- 安卓原生代理透传该只读二进制订阅。默认首屏及返回首页为总览；通过原生受保护本地存储，按服务器/证书、安装及账号保存上次站区、卡片/整表模式和分组位置。恢复时重新检查授权可见站区，不改服务器总览配置。
- 手机历史报警与所有共享报表表格默认记录卡片：先显六项、可展开余项、可切完整表格；完整字段、长值、十进制、NULL/零、CSV和现有查询/目录保留。覆盖普通历史、小时、日、月、采暖季、能耗、结算、自定义报表；同期对比沿用其手机汇总卡片和曲线。

## 验证

| 范围 | 本轮结果 |
| --- | --- |
| Go | Go1.27.3完整 `go test ./...`、`go vet ./...`通过。专项包括原生HTTP/2 gRPC、gRPC-Web、真实TLS/WAF、Cookie/KP、公网只读、范围裁剪、撤销、旧SSE及流协议状态 |
| Flutter | Flutter3.35.4/Dart3.9，analyze通过；694测试通过，2既有跳过。含protobuf分帧/状态、手机320/390布局、展开/整表切换、安卓位置恢复/重挂载/授权失效 |
| 安卓 | 20单元测试、Lint及release编译通过；包括实际mTLS二进制代理与旧SSE、原生位置持久化和账号隔离。不是安卓真机安装证明 |
| 包一致性 | Windows/Web同源构建，最终载荷逐文件摘要；两个APK均同历史签名，固定地址/服务器证书保持，分别核验5743项Web资源 |
| 实际浏览器 | Chrome正式编译Web＋正常API登录的隔离实例：新服务器仅发RPC POST并显示总览数值；断网恢复后重建RPC；新Web接实际v74服务仅发SSE GET并显示同一总览。安卓入口参数在390px默认打开总览 |
| 视觉 | 390×844检查历史报警、普通历史、小时/日/月/采暖季报、能耗、结算、同期对比、自定义报表及手机总览截图。使用合成数据，无现场SQL连接 |
| 安装与回退 | 独立目录/工程执行v74→v75→v74，启动、正常账号登录、覆盖/重装/卸载保数据。5019变量、31图、设备审批/证书、账号/MFA、图片、来源、菜单、共享价格、KP配置保持；12表中11表摘要完全相同，审计表原全部记录摘要相同，仅新增验证登录记录；非操作工程文件字节保持 |
| 清理 | 测试后台/PG及35219/42517/18184/55436监听停止，测试安装注销并恢复原快捷方式。未关闭用户软件 |

证据：[发布摘要及文件SHA](evidence/20261111-v75/release.json)、[安装回退](evidence/20261111-v75/installer.json)、[审计追加核对](evidence/20261111-v75/rollback-audit.json)、[Go](evidence/20261111-v75/go-result.json)、[Flutter](evidence/20261111-v75/flutter-result.json)、[安卓](evidence/20261111-v75/android-result.json)、[视觉检查](evidence/20261111-v75/visual-final.log)。

截图：[报警](evidence/20261111-v75/alarm.png)、[结算](evidence/20261111-v75/settlement.png)、[自定义报表](evidence/20261111-v75/custom.png)、[同期对比](evidence/20261111-v75/comparison.png)、[总览](evidence/20261111-v75/browser-overview.png)、[v74回退连接](evidence/20261111-v75/rollback-overview.png)、[手机总览](evidence/20261111-v75/手机总览示例.png)。

## CI与限制

源码437d4376的[Linux生命周期](https://github.com/YufeiSun5/universal-hmi/actions/runs/42988769569)成功。[跨平台CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/42988769652)首轮Windows/Linux后端及Android成功；macOS后端包测试达到Go默认10分钟总超时，当时正在运行的旧SSE撤权测试只有12秒，未出现断言失败，identity包race测试耗时474秒。已针对失败作重试，核对时macOS在途，Flutter/组合包受前置依赖尚未执行；不能写成远端全通过，也未据此合并main。未修改超时门禁或略过测试。

安卓真机覆盖安装/回退、现场KP代理链路及多客户端长时负载未实测；本批不宣称传输延迟或吞吐提升。Windows安装器仍未做Authenticode签名。浏览器安卓参数测试不能替代原生WebView/Keystore真机验收。

## 独立交付与回退

系统下载目录 `D:/Users/SunYufei/Downloads`：

1. `Universal-HMI-20261111-Full-v75-Setup.exe`：完整服务器/Windows/Web安装器。
2. `Universal-HMI-Android-v75.apk`：正常更新，同原签名，安装版本号75。
3. `Universal-HMI-20261111-Full-v74-Setup.exe`：上版完整服务器回退，摘要与v74原交付相同。
4. `Universal-HMI-Android-Rollback-v58-code76.apk`：上一版已发布v58安卓功能和Web，原签名；只提高安装版本号至76，让Android可覆盖回退而保留设备密钥/本地数据。源码取b808c74e，其安卓实现与已发布v58相同，仅版本元数据变化。
5. `v75-更新与回退说明.txt`、`v75-SHA256.txt`。

正常先覆盖服务器，旧安卓可继续用；安卓升级按需覆盖安装。回退服务器覆盖相同安装目录/工程路径，不重置工程；新客户端可继续连接旧服务器。安卓回退APK仅在需要撤回手机功能时安装，禁止先卸载或清除数据；安装76回退包后，后续正常APK版本号必须至少77，不能再直接覆盖75。会话失效可重新登录，不因此重建账号或设备。完整步骤见交付说明；不输出ZIP。
