# KP 登录与 Web 会话联动合同

## 2026-10-27 统一身份模式

正式TLS部署可同时启用 `--identity --kp-config`，不能与 `--kp-local-trial` 或 `--identity-local-setup` 组合。KP配置中显式subject的user_id必须对应统一身份库里已创建的稳定用户ID；账号角色、数据范围及控制能力以统一用户授权为准，旧viewer/operator字段不能赋予工程师或控制能力。

可信HTTPS verifier响应除subject/username外需返回 `mfa_verified: true` 和RFC3339格式 `authenticated_at`。认证时间须近期（15分钟内）；这是可信验证服务确认的认证事实，不从客户端bootstrap请求读取。旧verifier没有这两项时旧模式仍兼容，但统一身份模式拒绝接入。一次性兑换后关联统一会话，检查KP实例有效性、8小时绝对/30分钟空闲期和用户权限版本；统一撤销或KP退出任何一个发生都拒绝业务及备用认证路径，不能重新兑换旧token恢复。

HTTP/MCP、实时/SSE、历史、画面/菜单、任务及控制使用共同Actor；额外画面不附带跨站变量读取。统一安全管理员可撤销关联会话，KP仍负责真正的LogOff；原实例隔离和未知现场动作语义保留。实现回归见 [安全验证](security-verification.md)。以下全工程viewer/operator描述为历史兼容模式；运行中的18139本机试验未切换，真实verifier和证书仍待AUTH-DEPLOY验收。

2026-10-10，基点 b56ae1f，属于本轮源码实施。产品母本 [agent.md](../../agent.md)，分层母本 [architecture.md](architecture.md)。真实 KP 对接由操作方完成；下面是可交付的接口及边界，不是现场部署结论。

## 分工与文件

| 责任 | 实施方 / 路径 |
| --- | --- |
| 登录、当前 KP 用户、登录/退出事件、容器 setURL、定时器、LogOff 和回登录页 | KP；示例在 [examples/kp-bridge](../../examples/kp-bridge/README.md) |
| 取得真实 KP 身份凭据、校验 KP 会话和签名、稳定 subject、确认证书与身份受众 | KP 集成方的可信服务；调用下述 verifier 契约 |
| 关联会话、一次性票据、撤销/心跳/绝对过期、并发实例 | Go [kpbridge](../../backend/internal/kpbridge/service.go) |
| HTTP/CORS/Host/TLS、嵌入静态入口、统一 Principal、只读拦截 | Go [kp.go](../../backend/internal/server/kp.go)；配置 [kp_config.go](../../backend/internal/server/kp_config.go)；装配 cmd/server |
| ticket 兑换、Web 会话、退出即清理私有页面/弹窗/旧请求 | Flutter shared/api.dart、main.dart、features/kp_session.dart |
| URL 片段、浏览器每窗口 sessionStorage、平台条件导入 | Flutter platform/kp*.dart；桌面无 KP 模式副作用 |

业务状态只有 kpbridge 一个权威，handler 不复制会话规则；前端只显示返回状态并清理页面。全部业务仍经已有 API，MCP 使用相同 Principal 和读写注册表，写工具还需 `--mcp-write`。无新增运行时依赖，Node 只用于脚本模拟测试。

## 多用户、多 IP、同账号多终端

关联会话按 **sourceId（本进程配置）+ contextId + loginVersion** 区分。KP 每次登录必须生成新的 contextId 和 loginVersion；它们是关联标识，不是身份凭据。认证还要求独立随机 bridgeToken 或 webToken。不同账号、同账号多个 IP、同 IP 下多个用户/终端均不互相覆盖。只退出当前实例，不提供“注销账号全部终端”接口。

IP、kpHost、Origin 均不能证明身份。HTTP 只记录 bootstrap/redeem 首次请求的实际 RemoteAddr 为 kpObservedIp/webObservedIp，忽略客户端提供的 Forwarded/X-Forwarded-For；这两个字段是关联元数据，不是完整审计日志。VPN/DHCP 导致 IP 改变不撤销凭据。NAT 多用户共用 IP 不合并会话。未配置可信代理链，正式部署当前要求 Go 实际承载 TLS；不能仅凭转发头伪装 HTTPS。

Web token 位于当前顶层窗口、当前源的 sessionStorage，KP bridgeToken 位于 KP 自己源的 sessionStorage；不使用共享 Cookie 判断 KP 用户。符合方案的一个 KP 登录窗口只有一个 Web 容器；同一窗口多个同源容器不属于独立会话承诺。复制浏览器标签可能复制 sessionStorage，必须由 KP 新登录事件生成新关联后加载新 ticket，不能将复制标签视为已获得独立登录。新 ticket 会先清理旧 Web token，再兑换；旧异步响应按 generation/context/version 丢弃。

**当前只有一个共享工程**，workspace_id 是这个 Go 数据目录的稳定标签。显式 users grant 的 viewer 能读整个工程，operator 能修改整个工程和使用已有受控写入服务。它不表示每个用户只有自己的站点、模板、文件或历史。未实现按站点/租户权限过滤，不接受看似具有局部授权的配置。需要严格用户数据隔离时，应先扩展业务用例的授权过滤，或给不同工程部署独立 Go 实例与数据目录。共享工程的协作保存仍使用既有版本冲突保护。

已受理的受控写入、文件任务、共享采集、条件事件和存储不会因一个用户退出而停止；退出阻止后续业务请求，前端丢弃旧响应，不撤回已经受理的现场动作。Web 的退出成功只代表业务撤销；真实 KP `LogOff(true)` 才代表 KP 确认。**真实 KP 的 LogOff 是否为当前登录实例、是否影响同账号其他机器，必须在 KP 侧核实**，后端的实例隔离不能改变 KP 自身的注销范围。

## 会话和失效

- bootstrap：可信 verifier + 显式 subject grant → created。桥接随机 256 位 token 与随机票据；票据默认 30 秒、仅兑换一次。
- redeem：created → active，生成独立 Web token；服务端只索引 Web token 的 SHA-256。桥接 token 无权读取业务，Web token 无权调用 KP poll/close/logoff-result。
- Web logout：active → logout_requested，业务访问立即撤销，仅保留 Web status/logout；前端在提交 HTTP 前移除工作区和弹窗。提交失联时可重试，刷新也不会恢复业务。
- KP poll：返回 logout，KP 调用 LogOff；回调严格 false 时保留退出意图；严格 true 后 closed。重复退出/回调/关闭不会重开会话。
- 心跳：仅 KP poll 延长 lease，默认 30 秒，可配置 15–600 秒；Web status 和业务访问不能延长。绝对期限默认 8 小时，可配置 60–86400 秒。
- 超时/重启：会话 expired，不能靠迟到心跳复活；正常过期 poll 返回 rebootstrap，重新获取可信凭据并使用新代次。退出意图未完成时即使过期，poll 仍返回 logout，禁止自动重新进入业务。closed 返回 closed，KP 保持空白/停止本代次。
- terminal 状态保留 2 分钟用于状态查询/幂等通知，之后清理；KP 本地已记录的退出意图继续有限 LogOff 重试。服务重启所有关联凭据失效；旧票据或旧 token 不恢复。

状态表有界，默认最多 256 个含短期终态的实例。bootstrap/redeem 合计每分钟最多 120 次，可信验证最多 8 个并行调用、5 秒超时。超过边界返回显式 429/503；不会按 IP 踢掉某个用户。后台受限/休眠的浏览器可能暂停 2 秒定时器，lease 要根据现场延迟合理设置，避免将单个标签休眠误当整个账号退出。

## HTTP 接口

容器清空地址：`GET/HEAD /blank.html` 返回真正的空白 HTML（200、no-store，无脚本或业务资源），由 Go 内置，不依赖 Flutter 文件。KP 模式在没有会话/退出后也可加载，仍校验配置 Host/HTTPS，嵌入来源沿用 exact KP origins；本机模式可直接访问，纯空白页允许不同端口的本机容器嵌入，不设置 frame-ancestors/X-Frame-Options。KP 容器使用 `WebContainer1.setURL(base + "/blank.html")`，不能使用不被其接受的 `about:blank`。这是页面导航地址，不是会话接口，不执行退出或建立登录；独立账户模式的原认证入口不变。HTTP200 不能证明 iframe 加载成功，须验证 iframe 中无 Chrome 错误页与 CSP 拦截。修复记录见 [空白页兼容验证](kp-blank-verification.md)。

所有成功响应为 JSON 并含 `ok:true`；错误为 `{"error":{"code":"...","message":"..."}}`，同时使用 HTTP 错误状态。POST 必须是单个 JSON 对象、最多 32 KiB、拒绝未知字段和尾随内容。接口不接受查询参数作为登录凭据。

| 方法 / 路径 | 凭据 / 请求 | 成功结果 |
| --- | --- | --- |
| POST /api/v1/kp/bootstrap | 下方 Bootstrap，identityProof 经可信服务验证 | contextId/loginVersion/bridgeToken/ticket/ticketExpiresAt/pollIntervalMs |
| POST /api/v1/web/redeem | `{"ticket":"一次性票据"}`，无其他凭据 | 下方 WebView + webToken |
| GET /api/v1/web/me | Authorization: Bearer webToken，active 才成功 | WebView，不重复返回 token |
| GET /api/v1/web/status | 同上；允许查询短期退出/终态 | WebView |
| POST /api/v1/web/logout | 同上，body `{}` | WebView；幂等 |
| POST /api/v1/kp/poll | Channel | contextId/loginVersion/state/command，command=none/logout/rebootstrap/closed |
| POST /api/v1/kp/logoff-result | Channel + `"success":true` 或 false，缺失/null 不接受 | state/User 等关联视图，非业务重登 |
| POST /api/v1/kp/close | Channel | state/User 等关联视图，幂等 |

Bootstrap 请求：

```json
{"contextId":"kp-window-unique","loginVersion":"new-login-unique","userName":"KP 当前用户名","kpHost":"KP 主机（仅元数据）","identityProof":"短期可信身份凭据"}
```

Channel 请求：

```json
{"contextId":"kp-window-unique","loginVersion":"new-login-unique","bridgeToken":"bootstrap 返回的桥接凭据"}
```

WebView 除 contextId/loginVersion/state 外包含：enabled/authenticated/username/can_write/expires_at；user 为 `{id,name,role,workspace_id}`；sourceId/kpHost/kpObservedIp/webObservedIp/lastLogoffResult。只有 redeem 返回 webToken。退出/终态 authenticated=false、can_write=false。不要把 ok=true、关闭应答或业务撤销当成 KP 成功注销。

常见错误：400 invalid_request/success_required；401 identity_proof_required/identity_not_verified/invalid_web_token/invalid_bridge_token/business_session_revoked；403 identity_mismatch/user_not_provisioned/write_forbidden/origin_rejected/invalid_ticket/ticket_used_or_expired；409 identity_conflict/login_already_started/unexpected_logoff_result；429 bridge_rate_limited；503 identity_verifier_unconfigured/identity_verifier_unavailable/identity_verifier_busy/bridge_capacity_reached。已被兑换的 ticket 无法再次取得丢失的 Web token；兑换响应丢失且窗口没有 token 时，从 KP 重新登录建立新代次。

## 加载和构建资源

登录加载优化接法：将配置好的 `kp-page-timer.js` 放到KP自定义脚本 `UniversalHmiKPBridgeTick(WebContainer1)`，在承载页打开事件及唯一2秒定时器中共用 [kp-page-dispatch.js](../../examples/kp-bridge/kp-page-dispatch.js) 的调用，消除等待首次定时触发的固定延迟。仍由原登录事件生成新关联，原状态机防止在途重复/旧代次进入；登录、退出、LogOff确认与凭据合同不变。完整步骤见 [对接入口](../../examples/kp-bridge/README.md)。该配置需要操作方在KP应用，提供示例文件不表示现有项目已修改。

`/kp/main.dart.js`、`/kp/canvaskit/`、`/kp/assets/` 是无用户身份/业务数据的公开构建资源，响应 `private, no-cache`，每次复用重新验证；HTML、bootstrap/Service Worker、空白页、会话/API/错误保持no-store。缓存只减少未变文件的重复传输，不替代认证或会话检查。实际浏览器仍重传完整中文字体的范围见 [性能验证](kp-performance-verification.md)。

## 可信身份验证端口（留给 KP 对接）

配置 verifier_url 是操作方固定的 HTTPS URL，不能由请求者指定。Go POST 给它：sourceId 加 Bootstrap 全部字段；不跟随重定向，不忽略证书错误。服务成功响应严格为：

```json
{"verified":true,"sourceId":"kingportal-site","contextId":"kp-window-unique","loginVersion":"new-login-unique","subject":"KP稳定用户ID","userName":"KP当前用户名"}
```

验证端必须自行校验真实 KP 登录是否仍有效、凭据签名/撤销/受众/短期有效期，并把凭据绑定到 sourceId/contextId/loginVersion。不能仅回显传来的 userName 并返回 verified=true。建议身份凭据有效期不超过 60 秒，重放策略与 bootstrap 重试协调；本接口不替代 KP 可信凭据校验。Go 会检查返回绑定、用户名一致、显式稳定 subject 授权；响应最多 32 KiB，未知字段/尾随内容拒绝。

KP 中需要实现 `KPBridgeIdentityProof(binding, callback)` 将真实凭据交给 bootstrap；这个名称是我们预留的集成函数，**不是已核实的 KP 内置函数**。实际 KP SSO/token/服务端查会话机制由你选择并实现上述可信端口，当前没有假设某个厂商令牌格式。

## 配置与启动

未传 `--kp-config` 时保留既有本机/独立登录行为。正式样例 [bridge.example.json](../../examples/kp-bridge/bridge.example.json) 不包含密钥、默认账号或有效凭据；先复制到操作方私有配置，填真实 verifier_url、KP exact origin、subject/user_id/grant。Linux/macOS 配置 0600，Windows 使用只允许运行账户/管理员读取和修改的 ACL；证书和密钥由操作方保管。

```text
universal-hmi-server --listen 0.0.0.0:18443 --data-dir <该工程目录> --web-dir <release Web目录> --public-origin https://hmi.example --tls-cert <cert.pem> --tls-key <key.pem> --kp-config <私有bridge.json>
```

默认 KP-only：公共 /kp/ 只提供静态 Web 壳，业务必须有效 Bearer；不存在本机业务绕过或自动创建用户。可显式另设 --auth-file 保留独立管理员登录，两种凭据各自撤销；KP 入口始终使用自己的 token。外层只接受实际 HTTPS 和配置 Host。KP API CORS 仅配置 exact origins，Web API 和业务仅同源；frame-ancestors 仅 self/配置 KP origins，禁止通配。KP 与 Web 都使用 HTTPS，不能产生混合内容。

本机隔离模拟（不接 KP、不接现场设备）：

```text
universal-hmi-server --listen 127.0.0.1:18145 --data-dir .local/kp-trial/data --web-dir app/build/web --public-origin http://127.0.0.1:18145 --kp-config examples/kp-bridge/bridge.trial.example.json --kp-local-trial
```

显式试验只接受回环监听/HTTP 回环来源，不能与 auth-file/TLS/dev-origin 混用，也不能配置正式 verifier_url；subject 此时等于用户名，必须在操作方配置的 users 白名单中。样例只配 trial-viewer/trial-operator，不自动认可其他用户名。未启用此 flag 的正式模式若 verifier_url 留空，bootstrap 必须 503。

2026-10-13 用户授权18139本机KP联调，采用私有单用户白名单和实际11005来源，使用现有本机试验凭据脚本；本机配置/启动文件和验收见 [本机启用记录](kp-local-trial-verification.md)。它没有验证正式KP身份，不作为多IP部署配置。

## 本轮验证范围

状态、HTTP、可信验证和 Flutter/脚本回归的实际结果及浏览器/构建证据见 [本轮验证记录](kp-bridge-verification.md)。NAT/多 IP 在服务用例与 HTTP fixture 注入连接地址验证；真实多个现场 IP、真实 KP 凭据、LogOff 作用域、KP 嵌入浏览器的 Cookie/存储限制和后台定时器、实际内网证书/权限部署尚未验收。
