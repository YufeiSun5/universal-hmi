# KP 对接入口

完整接口、权限与现场边界以 [KP 联动合同](../../.ai/docs/kp-bridge.md) 为准。

- `kp-login.js`：KP 成功登录事件，每次登录生成新的 contextId / loginVersion。
- `kp-page-timer.js`：承载页 2 秒定时器，空白→身份凭据→bootstrap→WebContainer1；poll 获取退出指令，调用 LogOff 并上报布尔结果。
- `kp-page-dispatch.js`：快速启动接法，在承载页打开时立即调用同一联动逻辑；2 秒定时器继续调用它。
- `kp-close.js`：KP 退出事件，先清空容器和关联状态，再关闭相应后台会话。
- `bridge.example.json`：正式配置骨架。verifier_url 留空时 bootstrap 返回 503，不允许按用户名登录。
- `bridge.trial.example.json`：显式本机模拟用；必须同时指定 `--kp-local-trial`，不能用于远程部署。

三个脚本中的 `https://hmi.example.invalid` 改成同一个实际 Web HTTPS 地址。定时脚本的 sourceId 必须与 Go 配置一致。`WebContainer1` 改成实际容器名称。

只在 2 秒定时器里执行加载脚本，会在登录后额外等待第一次触发。要消除这段等待，在 KP「命令语言 → 全局脚本 → 自定义脚本」创建 `UniversalHmiKPBridgeTick`，参数填 `(WebContainer1)`，内容使用配置好 base 和身份凭据接口的 `kp-page-timer.js`。承载页「连接 → 打开时」和唯一的 2 秒定时器都填写 `kp-page-dispatch.js` 中的同一行调用。用调用替换原定时器里的完整加载脚本，保留事件中与联动无关的逻辑。共用一个脚本避免维护两份会话规则；在途请求锁和请求代次保护仍防止重叠 bootstrap 和旧响应进入。登录/退出事件和容器默认 `/blank.html` 不变。

KP 页面和计时器配置由集成方应用；这里提供的文件不会自动改动现有 KP 工程。Go 对 `/kp/main.dart.js`、`/kp/canvaskit/`、`/kp/assets/` 允许浏览器保留构建资源，但每次复用都须重新验证（`private, no-cache`），未变返回 304，更新后重新下载。HTML、bootstrap/Service Worker、会话和业务 API 继续 `no-store`，不会缓存用户身份或业务数据。

清空容器统一使用 `WebContainer1.setURL(base + "/blank.html")`。KP 容器只接受 HTTP(S) 地址，不能使用 `about:blank`。Go 服务内置这个空白页，不依赖 Flutter 构建文件；本机模式和 KP 模式均可直接 GET/HEAD，KP 模式退出后也无需凭据。页面不加载脚本或业务，访问成功不代表 KP 已注销；KP 模式仍按配置的 exact origins 允许嵌入，本机模式的纯空白页允许跨端口嵌入。可以先在浏览器打开实际 `base + "/blank.html"` 确认 HTTP 200，再验证 KP iframe 中没有 Chrome 错误页或 frame-ancestors 拦截；显示空白是正常结果。三个脚本的 base 都不带结尾 `/`。

同一 `127.0.0.1` 的不同端口也是不同来源。`kp_origins` 应包含实际 KP 页面来源，例如 `http://127.0.0.1:11005`；样例的 18146 仅是独立试验来源。没有指定 `--kp-config` 时，服务仍是普通本机模式，KP bootstrap 接口返回 404，空白页加载成功也不会自动建立 KP 登录。启用联动须按合同配置身份来源和 subject/角色；本机模拟还须显式指定 `--kp-local-trial`。

集成方需要提供异步函数 **KPBridgeIdentityProof(binding, callback)**。它不是 KP 内置函数：binding 包含 sourceId/contextId/loginVersion/userName；callback 返回短期可信身份凭据字符串。正式模式不能在此返回用户名、固定密钥或模拟值。可信验证服务需要按合同校验真实 KP 登录、受众、有效期及 binding，返回稳定 subject。

如果暂时只跑显式本机模拟，可以定义 `KPBridgeIdentityProof = function (binding, callback) { callback("local-trial-only"); };`，同时将三个脚本的 base 改成 `http://127.0.0.1:18145`。这段函数仅方便模拟，正式服务不会认可它。

脚本假设 httpRequestExec 回调直接提供响应 JSON 对象或 JSON 字符串；不同 KP 版本若包了一层响应对象，需要在 `request` 的 callback 处适配。LogOff 仅严格布尔 true 算确认成功；最多 3 次、间隔至少 8 秒，失败后业务仍关闭，需在 KP 侧处理。尚未部署真实 KP。

模拟回归：`node examples/kp-bridge/test_kp_scripts.cjs`。它验证异步与隔离，不证明真实 KP 的登录/退出范围。浏览器验证用的替身页面和凭据不随发布包开放。
