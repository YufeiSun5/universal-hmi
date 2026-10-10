# KP 接口实施与隔离验证

2026-10-10。实现基点 `b56ae1ff9d76eaea14d11585d7fac38020eb0a85`，分支 `codex/process-canvas`，沿用 [PR #14](https://github.com/YufeiSun5/universal-hmi/pull/14)。产品要求在 [agent.md](../../agent.md)，唯一分层合同在 [architecture.md](architecture.md)，对接说明在 [kp-bridge.md](kp-bridge.md)。本记录是本机源码、模拟和浏览器验证，不代表真实 KP 或现场部署验收。

## 实施范围与文件组织

新增 `backend/internal/kpbridge`，只拥有身份验证端口、关联会话和状态；不访问业务数据或 Flutter。HTTP 和部署检查放 `backend/internal/server/kp*.go`，在 `cmd/server` 显式装配。业务复用既有 HTTP/MCP 与统一 Principal，未复制点位、写入、文件任务规则。

Flutter 的协议与请求退役在 `shared/api.dart`，浏览器片段和每窗口存储在条件导入的 `platform/kp*.dart`，状态页在 `features/kp_session.dart`。会话变化替换 Navigator 和 ScaffoldMessenger，移除私有路由/草稿/弹窗并清理焦点，保留 MaterialApp 的根焦点树。KP 状态切换不自动请求焦点，旧导航清理期间短暂阻止新导航的排队 autofocus，清理完成后恢复用户点击/键盘进入。KP 事件脚本、配置骨架和模拟测试在 `examples/kp-bridge`；仅本机 QA 替身位于忽略目录，不开放在正式发布包中。

这种划分沿用现有单体与平台适配边界，不按每用户创建后端/数据库副本，无新增运行时依赖。Node 仅用于开发及 CI 脚本测试；Go/Flutter 锁文件未变。默认服务不启用 KP。正式启用必须实际 TLS、明确用户 grant 和可信 verifier，缺少 verifier 不以用户名代替身份。

## 自动验证

固定工具链 Go 1.24.7、Flutter 3.35.4 / Dart 3.9.2；每个命令先执行 `.local/Activate.ps1`（子目录用 `../.local/Activate.ps1`），检查不写格式或依赖锁。最终构建源码摘要：`919830a43db566dae9b84e96217008801c79188ce94eb582bb5466357510546a`。

| 检查 | 实际结果 |
| --- | --- |
| backend `go test -mod=readonly ./...` | passed，9 个包；全库 150 个 Go 顶层测试，不以子测试冒充数量 |
| backend `go vet -mod=readonly ./...`、`gofmt -l ./cmd ./internal`、`go mod verify` | passed；无格式输出，依赖校验通过 |
| Flutter `flutter analyze --no-pub` | passed，无问题 |
| Flutter `flutter test --no-pub test` | passed，140 项，包括既有独立登录和工艺画面回归 |
| Dart 只读格式门禁 | passed，75 个文件、0 修改 |
| `node examples/kp-bridge/test_kp_scripts.cjs` | passed，17 项模拟 |
| `python ci/build_release.py windows` / `web` | passed，同一最终源码摘要 |
| Windows / Web `--verify-only` | passed，产物/源码/锁检查 |
| 本机 Go `-race` | failed（环境），CGO_ENABLED=0 且未配置 C 编译器；不能据普通测试宣称 race 通过 |
| 最终提交 CI | 提交后独立查询 PR #14 的对应 head，不能沿用基点的成功 |

Go 专项覆盖：多账户、同账号多个 IP、共享 NAT、地址变化、同名不同登录代次、身份关联冲突、并发 16 次兑换只有一次成功、跨通道凭据拒绝、心跳/绝对期限、过期退出意图不重登、迟到/重复 false/true/close、容量清理和重启。HTTP fixture 检查只读写入 403、撤销后业务 401、转发头不作为身份、CSP/base/CORS/实际 TLS、严格 JSON 和空 verifier。可信验证适配器检查绑定、拒绝/不可用、重定向、未知/尾随和超大响应。

Flutter 专项覆盖：无票据不出现独立登录/业务、票据兑换及窗口刷新、失败新票据清除旧凭据、退出提交前立即移走私有页面、旧响应不能污染新会话、退出提交失败后刷新仍保持关闭、离线退役旧请求、同账号不同窗口单独退出。UI 回归包括私有弹窗销毁，以及焦点在 KP 宿主页时的关闭通知不抢焦点、随后 Tab 进入无异常；“不抢焦点”断言经历失败→修正→通过。KP 脚本检查新登录、用户变化/同名重登、旧凭据回调、超时/迟到结果、有限注销重试及关闭后不重开。

## 实际浏览器验证

使用独立 Playwright Chrome 会话，测试后端 `127.0.0.1:18145`，KP 替身 `127.0.0.1:18146`；独立数据目录 `.local/kp-bridge-20261010/data`，未接设备。替身只证明本应用的嵌入和 HTTP 状态，不证明实际 KP 的 httpRequestExec/LogOff 行为。用户的 18139 页面未刷新，原画面目录未写入。

| 操作 | 观察结果 |
| --- | --- |
| 同源 Web 构建经 `/kp/` 在跨源 iframe 接入 | 静态资源正常，兑换后地址片段清除，当前窗口存储独立凭据 |
| 同一浏览器配置的两个顶层窗口使用相同 trial-operator | 同时 active；第一个退出后第二个仍能访问业务 |
| 第一个点击真实 Flutter 退出，替身返回 LogOff=false | 私有工作区移除，状态 logout_requested / authenticated=false，等待 KP；不恢复业务 |
| 替身改为 LogOff=true | Web 显示关闭状态，窗口凭据删除 |
| 第二窗口刷新 iframe | GET status 200 恢复同一活动实例，无重复 redeem |
| 第三窗口 trial-viewer | me 返回只读角色；读取 points 200，PUT points 403，前端 can_write=false |

第一次浏览器操作观察到焦点异常。debug 构建定位到 KP 宿主页持有焦点时，关闭通知的新 Navigator 自动抢焦点，引起 ReadingOrderTraversalPolicy 访问旧导航内已失活 Element 的 TypeError；仅保留根焦点与 unfocus 不足以解决。最终阻止这一帧的自动焦点请求，新增可复现回归后完成全量测试、两端 release 及浏览器复测。最终 false 回调 HTTP 200 / lastLogoffResult=false / authenticated=false，true 后凭据删除；实际关闭通知和 Tab 均无 pageerror/控制台错误。页面有一条 Flutter service worker 启动超过 4 秒的警告，主页面资源与业务加载成功，不把警告计为“零警告”。最初替身 favicon 404 已在替身修正；旧测试通道在测试服务重启后收到预期 401，与最终焦点回归分别记录。结果和截图见 [证据摘要](evidence/20261010-kp-bridge/verification.json)。

## 未执行与现场边界

真实 KP 身份凭据/可信验证服务、实际多 IP 机器、KP 内嵌浏览器存储限制/后台定时器、内网证书/权限配置、真实 LogOff 对同账号其他机器的影响尚未执行。多 IP/NAT 目前是 Go 用例与 HTTP RemoteAddr fixture；浏览器用例共享本机 IP。

当前角色授权整个共享工程，不是逐用户站点/文件/历史隔离。共享采集、存储、条件事件和已受理受控动作/文件任务不因单个用户退出而终止。退出撤销后续业务访问，不撤回已受理动作。真实 KP 自身若全局注销同账号，应用的独立会话不能改变厂商行为，必须由现场确认并适配。
