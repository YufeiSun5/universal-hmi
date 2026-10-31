# KP 容器 HTTP 空白页兼容验证

## 2026-10-13 跨端口嵌入修复

用户在 KP 11005 端口的运行页截图中看到 iframe 内「127.0.0.1 拒绝了我们的连接请求」。18139 实际仍在监听，health=ok，GET `/blank.html` 为 200。旧实现给本机空白页设置了 `frame-ancestors 'self'`，同主机不同端口仍是不同来源，因而会被 Chrome 拦截。此前只验证 HTTP200，未覆盖跨端口 iframe，这是上一轮验证的缺口。

独立 Chrome 隔离上下文以 `http://127.0.0.1:18147/` 承载 18139 的空白页：修复前复现同样的灰色拒绝连接画面，子 frame 为 `chrome-error://chromewebdata/`，控制台明确报 frame-ancestors self 拦截。修改 `backend/internal/server/server.go`：仅本机纯空白导航不设置 frame-ancestors/X-Frame-Options，仍禁止页面加载资源、脚本、base 和表单；正式 KP handler 继续传入原显式来源白名单，Host/TLS/API/权限契约保持。

固定 Go1.24.7 的 `go test -mod=readonly ./...`、`go vet -mod=readonly ./...`、Windows 服务 build 全部 passed。原空白页回归增加检查本机不得携带嵌入限制、配置 KP 必须保留来源白名单；业务/Origin/会话既有回归同时通过。仅 Go 响应头和文档变更，没有修改 Flutter 或本轮重跑未改动的 JS。

18139 已以隐藏独立后台进程 PID68556 运行 `universal-hmi-server-blank-20261013.exe`，保留原数据与 Web 路径。GET/HEAD blank=200、POST=405、首页200、health=ok；三张用户画面摘要未变。重载独立测试页后，子 frame URL 为真实 `/blank.html`、画面为空且无 Chrome 错误图标，控制台无 error/issue/warn。见 [浏览器前后证据](evidence/20261013-kp-blank/browser.json) 与 [服务机器记录](evidence/20261013-kp-blank/verification.json)。截图已在本轮工具输出中查看，工具的文件路径限制使截图未存入仓库。

完成本次空白页修复时，18139没有启用 `--kp-config`，GET KP bootstrap 返回404；本轮不把空白页可嵌入称为 KP 登录已接通。后续已启用本机 KP 联调，当前状态见[联调验证记录](kp-local-trial-verification.md)。`kp_origins` 需按实际 KP 来源配置，11005 与样例18146不同。本轮未连接用户 Chrome（未开放调试），未修改或刷新实际 KP 页面，未执行真实 KP 登录/LogOff；真实壳验收仍归 AUTH-DEPLOY。基点CI不覆盖这些未提交的工作树修改。

## 2026-10-12 HTTP 地址兼容与历史验证

2026-10-12，基点 `f552d81cece70a3bc7f4287b228e15bbdd6c2108`。用户报告 KP 容器拒绝 `about:blank`，附件的承载页定时脚本有六处调用，仓库登录/关闭脚本各有一处。

实现属于 `backend/internal/server` 的静态入口与 `examples/kp-bridge` 的容器导航。Go 内置 `/blank.html`，本机模式和 KP 模式复用响应；KP 模式在会话鉴权前允许该精确路径，仍保留 Host/实际 HTTPS 与显式嵌入来源保护。它只返回空 body 的 HTML，不加载 Flutter、业务数据或脚本，不创建/注销会话，退出确认仍由 LogOff 及既有接口完成。独立账户模式的认证流程不变。

## 本次验证

固定 Go 1.24.7 windows/amd64：`go test -mod=readonly ./...`、`go vet -mod=readonly ./...`、Windows 服务 `go build -mod=readonly` 全部 passed。新增回归覆盖 WebDir 未配置的本机 GET/HEAD、拒绝 POST；正式 KP 无 verifier/无 WebDir/无会话或失效 token 也返回空白，禁止进入私有 handler，保留明确嵌入来源，错误 Host/实际 HTTP 仍返回 403。既有业务权限及会话回归保持通过。

`node examples/kp-bridge/test_kp_scripts.cjs` 的 17 项模拟 passed；容器替身现在验证所有导航必须是 HTTP(S)，保留换用户、迟到结果、有限退出重试等检查。附件六处替换后 `node --check` passed；原有 `base = http://127.0.0.1:18139` 与本机试验凭据函数保留，不声称它是正式凭据实现。

18139 服务已由新二进制作为独立隐藏后台进程启动，PID43368，保留原数据目录与 `app/build/web`。实际 HTTP 空白页 GET/HEAD 均 200、Content-Type text/html、no-store、body 空白；首页 200、health=ok、原本机登录检查 enabled=false 正常。三张用户画面 JSON SHA256 前后全部一致，没有刷新用户编辑页或启用 KP 配置。服务产物 SHA256 与响应见 [机器验证记录](evidence/20261012-kp-blank/verification.json)。

本机修正版脚本保存在 `.local/kp-blank-20261012/加载Web并处理退出-修正版.js`；登录/关闭事件同步提供本机 18139 副本。发布样例仍在 `examples/kp-bridge`，三个 base 应按现场一致配置。

本批没有修改 Flutter，不重建 UI。未执行真实 KP 容器/LogOff 或现场设备；这里只验证地址兼容实现及模拟会话流程。独立账户认证模式未增加公共绕过。基点完整 CI `38031925059` 和生命周期 `38031925060` 均 success，只是基点证据，不作为本次未提交修改的远端验证。
