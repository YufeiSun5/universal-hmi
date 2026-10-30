# 18139 本机 KP 联动启用记录

这是本机启用阶段的历史记录。后续缓存优化、实际KP登录测量和当前运行进程见 [加载性能记录](kp-performance-verification.md)，下文PID和未执行项仅代表启用阶段当时状态。

2026-10-13，用户确认后端未启用 KP 后要求按配置重启，并更正了当前 KP 用户名。此前 `/blank.html`200 但 bootstrap、`/kp/`404 的记录是当时的普通本机模式；当前状态以本记录为准。

## 配置与运行

本轮未修改 Go/Flutter 源码。复用前一轮通过 Go全量test/vet/build 的 `universal-hmi-server-blank-20261013.exe`，在忽略目录 `.local/kp-local-18139/` 新增操作方私有 `bridge.json`、`Start-KP.ps1`、`Verify-KP.ps1` 和本机说明。配置不进入发行样例或 Git，不包含 KP 密码；Windows文件 ACL 仅允许运行账户及 Administrators 访问。

source_id=kingportal-site，workspace_id=default，KP来源精确为 `http://127.0.0.1:11005`；仅用户明确提供并更正的账号在白名单，operator 允许原有模板编辑。无其他用户自动注册。运行参数增加 `-public-origin http://127.0.0.1:18139 -kp-config <私有bridge.json> -kp-local-trial`，监听仍为127.0.0.1。原数据 `.local/process-responsive/data` 和 Web `app/build/web` 保留，未接设备或启用采集配置。

显式本机试验与现用脚本的 `local-trial-only` 适配，仅以白名单用户名映射，不声称验证了真实 KP 登录身份。正式多IP部署仍需受信任HTTPS和真实身份verifier；不能将本次回环联调配置用于远程身份验证。用户授权仅覆盖本机联调，实际远程/多IP/真实LogOff边界仍在 AUTH-DEPLOY。

## 验证

先在隔离18145和独立数据目录验证配置，再以启动脚本替换经过完整路径/参数核对的18139进程。当前PID68856，health返回 kp_bridge=true/local_trial=true，二进制SHA256和本轮响应见 [机器记录](evidence/20261013-kp-local-trial/verification.json)。第二次执行默认启动脚本只复用相同进程，无再次重启；`-Restart`才重启匹配进程，其他端口占用者拒绝停止。

- `/blank.html`和`/kp/`200，base改写为`/kp/`，flutter_bootstrap.js200；空白和业务壳的嵌入白名单包含实际11005来源。
- 来自11005的OPTIONS204/CORS精确匹配；其他来源403，未配置用户403，匿名业务读取401。
- 独立测试context的bootstrap、redeem、me、业务读取、poll均200，用户映射正确且可编辑。
- 测试context的Web退出→poll logout→业务401→模拟logoff-result→closed→close均通过。这是自己的测试通道，未调用真实KP LogOff，也没有改业务数据。
- 独立Chrome中创建同源容器和2秒心跳，票据被兑换并从URL清除，页面实际显示既有工作区、站点与当前用户名；me200/authenticated=true/operator。无error/warn，有一项Intl.v8BreakIterator弃用issue。截图在本轮工具输出查看；[浏览器证据](evidence/20261013-kp-local-trial/browser.json)已去除票据。
- 三张用户画面JSON摘要前后相同。测试浏览器页、心跳和18145隔离进程已清理，18139持续以隐藏独立后台进程运行。

未刷新用户的实际KP或编辑页面，未运行真实登录/退出事件；用户下一步在KP退出后重新登录，获得新的context/loginVersion和票据。现用`D:/DEV_D/KS_HELP/output/KingPortal_Web联动`三段脚本已经是18139/kingportal-site/HTTP空白页/本机试验凭据，不需要替换协议。直接打开无票据`/kp/`不会建立登录，直接业务请求也不再走匿名本机模式。

没有新增源码或依赖，未重复前一轮已通过的Go/Flutter全量检查；本轮针对配置的HTTP、启动脚本语法/幂等和实际浏览器验收已通过。配置与用户画面不提交，远端CI不作为本机启用证据。
