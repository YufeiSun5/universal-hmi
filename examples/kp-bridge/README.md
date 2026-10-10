# KP 对接入口

完整接口、权限与现场边界以 [KP 联动合同](../../.ai/docs/kp-bridge.md) 为准。

- `kp-login.js`：KP 成功登录事件，每次登录生成新的 contextId / loginVersion。
- `kp-page-timer.js`：承载页 2 秒定时器，空白→身份凭据→bootstrap→WebContainer1；poll 获取退出指令，调用 LogOff 并上报布尔结果。
- `kp-close.js`：KP 退出事件，先清空容器和关联状态，再关闭相应后台会话。
- `bridge.example.json`：正式配置骨架。verifier_url 留空时 bootstrap 返回 503，不允许按用户名登录。
- `bridge.trial.example.json`：显式本机模拟用；必须同时指定 `--kp-local-trial`，不能用于远程部署。

三个脚本中的 `https://hmi.example.invalid` 改成同一个实际 Web HTTPS 地址。定时脚本的 sourceId 必须与 Go 配置一致。`WebContainer1` 改成实际容器名称。

集成方需要提供异步函数 **KPBridgeIdentityProof(binding, callback)**。它不是 KP 内置函数：binding 包含 sourceId/contextId/loginVersion/userName；callback 返回短期可信身份凭据字符串。正式模式不能在此返回用户名、固定密钥或模拟值。可信验证服务需要按合同校验真实 KP 登录、受众、有效期及 binding，返回稳定 subject。

如果暂时只跑显式本机模拟，可以定义 `KPBridgeIdentityProof = function (binding, callback) { callback("local-trial-only"); };`，同时将三个脚本的 base 改成 `http://127.0.0.1:18145`。这段函数仅方便模拟，正式服务不会认可它。

脚本假设 httpRequestExec 回调直接提供响应 JSON 对象或 JSON 字符串；不同 KP 版本若包了一层响应对象，需要在 `request` 的 callback 处适配。LogOff 仅严格布尔 true 算确认成功；最多 3 次、间隔至少 8 秒，失败后业务仍关闭，需在 KP 侧处理。尚未部署真实 KP。

模拟回归：`node examples/kp-bridge/test_kp_scripts.cjs`。它验证异步与隔离，不证明真实 KP 的登录/退出范围。浏览器验证用的替身页面和凭据不随发布包开放。
