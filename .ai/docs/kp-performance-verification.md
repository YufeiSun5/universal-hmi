# KP 登录加载性能验证

2026-10-13，基点 `f552d81cece70a3bc7f4287b228e15bbdd6c2108`，本批为工作树修改。用户确认采用此前接通账号进行本机测试；密码只用于独立浏览器登录，没有写入配置、源码或本证据。合同仍为 [KP联动合同](kp-bridge.md) 和 [架构](architecture.md)。

## 测量与归因

独立Chrome隔离上下文实际访问KP11005、完成登录并加载既有HMI工作区。KP认证请求约48ms，两次登录页DOMContentLoaded分别1370.7/912.8ms。登录后纯空白页开始到业务iframe导航分别2025.1/2032.8ms，对应承载页现有2秒定时触发。这个固定等待是已复现的延迟来源，不是认证本身耗时。KP壳共加载453个脚本，属于厂商运行时，本轮未改其实现。观察数据见 [浏览器记录](evidence/20261013-kp-performance/browser.json)。

HMI嵌入入口原先对所有构建文件no-store，主程序3333749字节、中文字体16437340字节、CanvasKit wasm5678018字节，每轮都完整传输。修复只允许公开构建资源保留在当前浏览器并每次重新验证。

隔离Chrome同源fetch两轮对比：原服务每轮25450007传输字节，修复服务首轮相同，第二轮16438240；主程序/wasm仅各300字节响应开销，文件内容SHA256完全一致。中文字体仍完整重传，原因没有证据支持定论；不能声称25MB降到1KB、全部命中缓存或整段登录加速倍数。服务器显式If-Modified-Since测试三个文件均304，是HTTP合同证据，与浏览器是否保留大字体分别报告。见 [缓存测量](evidence/20261013-kp-performance/browser-cache.json)、[实际18139响应](evidence/20261013-kp-performance/cache-headers.json)。

## 实施

- `backend/internal/server/kp.go`：仅main.dart.js、canvaskit/、assets/为private/no-cache；HTML、bootstrap/Service Worker、manifest、空白、会话、业务及错误仍no-store。Host/TLS/Origin校验和权限合同保持。
- `kp_test.go`：真实文件未变304、更新200新内容、壳/API/空白无缓存和错误Host403验证。复用Go FileServer，不新增缓存服务或依赖。
- [KP示例](../../examples/kp-bridge/README.md)：新增 `kp-page-dispatch.js`。把既有联动脚本放入一个参数化自定义脚本，在打开时和唯一2秒定时器共用调用；已有在途锁及代次保护不重复bootstrap。
- 操作方原目录 `D:/DEV_D/KS_HELP/output/KingPortal_Web联动` 新增快速启动调用.js，配置说明.txt追加配置步骤；原三段登录/加载/退出脚本保留。实际KP工程、页面事件和厂商源码未修改，操作方仍需应用打开事件接法。

浏览器原型在实际KP上下文调用同一登录/加载源脚本，测试容器适配器24ms内收到业务URL；它只测脚本到URL赋值，不测首屏可见，也不代替实际KP事件配置验收。最初从父页ResourceTiming观察原型导航未捕获事件，改用适配器记录赋值点，未把无事件当作产品失败或完整加载通过。

## 验证与部署

固定Go1.24.7 windows/amd64：Go全量test（9包）、vet、Windows服务build passed；KP脚本18/18及新增调用语法检查passed，git diff --check passed。未改Flutter，复用现有app/build/web。旧HEAD完整CI38031925059/生命周期38031925060成功，不覆盖本批未提交源码。

先在18145独立数据目录验证新二进制，再由私有Start-KP.ps1核对旧18139完整路径/参数后替换。当前监听127.0.0.1:18139，PID70860，binary `.local/kp-local-18139/universal-hmi-server-cache-20261013.exe`；默认重复启动复用，同源Web和原数据不变。health确认KP/local-trial启用；bootstrap/redeem/me/读取/poll和自有测试退出通过，匿名401、未知用户/来源403；三个静态资源200→304。原三张用户画面摘要保持，独立Chrome真实KP容器在后端更新后显示原有两个站点工作区。完整 [构建/运行记录](evidence/20261013-kp-performance/verification.json)、[HTTP会话记录](evidence/20261013-kp-performance/backend-session.json) 已剔除凭据；HTTP记录的actual_kp_login_logoff=not_run仅描述该独立验证脚本，真实登录另见browser.json，真实KP LogOff仍未调用。

当前还是回环local-trial用户名白名单。真实可信身份、多个现场IP、KP LogOff影响范围及应用快速打开后的端到端耗时继续由AUTH-DEPLOY验收。测试会话按自身context关闭，临时浏览器页及18145fixture清理；18139持续运行。未调用真实KP注销、设备下设或修改共享业务数据。

后端重启期间测试页记录过KP httpproxy400和旧业务读取401，随后原定时器重新建立会话并恢复工作区；没有将全程控制台称为零错误。浏览器原型测试曾临时导航到空白页，仅属于独立测试标签，没有刷新用户已有页面。
