# KP 对接与首屏加载 v51

本批为本地软件升级。产品母本为[agent.md](../../agent.md)，技术边界见[架构](architecture.md#kp原生令牌与gis首次加载2026-11-06)。

## 软件行为

- 后台直接调用 KP 的 `api/v1/getUserInfo` 核验现有令牌，再按稳定用户 ID 映射软件账号。复用现有后台和 HTTPS 入口，不需要中间服务，不保存 KP 密码。
- 账号权限仍由监控系统管理，KP 接入使用既有只读入口，原普通登录和 IP/设备准入继续适用。未映射账号不会自动创建或取得管理员权限。
- 每次心跳重新验证 KP 身份；换号、令牌失效、账号/设备停用或撤销后停止旧会话。网络暂断不续租，超过配置租约后需重新接入。
- GIS 首次用一张本地预览图直接显示展开后的庄河地图，首屏不下载全球底图及地球装饰。高清瓦片在交互/轮播时加载，地球演示和后续循环保留，在需要时加载资源。
- Web/嵌入页面在 Flutter 下载前显示加载动画；失败和慢网可重新加载。
- 账号创建、角色/范围授权、设备审批等管理操作取消15分钟内重新登录限制，仍需有效会话和相应管理权限。

## 一次配置

1. 安装新版软件，在开发端创建或选择用于 KP 的监控系统账号，分配站点、画面及能耗等读取权限。按原流程启用 HTTPS 和批准来源 IP/设备。
2. 将[配置样例](../../examples/kp-bridge/bridge.native.example.json)复制为实际工程目录的 `kp-bridge.json`。`kp_server`填写后台电脑能够访问的 KP 地址；同机通常是 `http://127.0.0.1:11005`，跨机使用可信 HTTPS。`kp_project`按实际 KP 工程填写，无需参数时留空。
3. `kp_origins`填写浏览器实际访问 KP 的来源地址（协议、主机、端口，不带路径），最多8项。`users[].subject`填写 KP 返回的稳定 `userId`（例如已验证的`2`）；`user_id`填写监控系统账号稳定ID，可通过本机已登录管理员的`GET /api/v1/security/users`取得。显示名称与角色字段不能替代稳定身份或提升权限。
4. 保存配置后使用软件原后台重启入口生效。此文件放在工程目录，不放进Web公开目录；升级保留工程。配置异常只停用 KP 接入，普通登录仍可用，原因写入后台启动日志。

## KP 画面脚本

画面添加网页容器，以下以`WebContainer1`为例。画面打开时只放这段，修改地址和控件名即可：

```javascript
var hmiBase = "https://监控系统地址:端口";
function openHmi() {
    window.HMIKP.open(hmiBase, WebContainer1, function () {
        return GetCurrentUser();
    });
}
if (window.HMIKP) {
    openHmi();
} else {
    WebContainer1.setURL(hmiBase + "/kp/kp-loading.html");
    var script = document.createElement("script");
    script.src = hmiBase + "/kp/kp_bridge.js";
    script.onload = openHmi;
    script.onerror = function () {
        WebContainer1.setURL(hmiBase + "/kp/kp-fallback.html");
    };
    document.head.appendChild(script);
}
```

画面关闭时：

```javascript
if (window.HMIKP) window.HMIKP.close();
```

不需要再配置KP页面定时器或重复粘贴桥接实现。软件附带的helper读取当前`WellinUserToken`，只通过POST提交，不放在网址或日志里。Web主动退出时仍需KP的`LogOff`明确成功回调，未确认时不会称为KP已退出。

## 验证边界

用户已在本机KP确认画面脚本可读取现有令牌，`getUserInfo`返回`userId=2/userName=admin001`。本批后台、HTTP全入口、脚本及实际浏览器采用隔离账号/合成KP接口验证；这些结果不代替现场多终端、真实LogOff范围和升级后KP完整联调。

## 本地验证

Go完整测试及vet、Flutter analyze、615项Flutter测试（2项既有浏览器专用跳过）通过。原生KP helper的8项脚本合同、原桥接18项合同和GIS轮播测试通过。完整公网入口回归覆盖跨域helper文件、KP页面根路径、IP准入、无效令牌、票据重放、账号映射、只读边界及旧会话撤销；24小时前登录的管理员可创建账号、修改授权与登记设备，普通用户仍不能管理。

实际Chrome使用隔离账号和合成KP核验服务，确认KP容器自动兑换票据、进入授权页面和读取数据；令牌失效返回401并移走旧业务画面。首次GIS只请求一张1518896字节的本地预览图，不加载地球影像；点击地球演示后正常加载地球、月球和卫星。实际阻断及延迟Flutter入口验证加载动画、慢网提示和失败提示，点击重新加载后可恢复Flutter。上述检查不代表现场KP联调通过。

Windows/Web来自同一源码摘要；安卓15项测试与lint、原签名、5742项内置资源核验通过。产品提交`4f1e96e680501b28f70376da055f9a78a51d36fa`，源码摘要`b6cf5869e1f1f973456609e3fb6b7aeb7242ca381a1ae5169d844e077b6c9fe1`。

## 安装与交付

v50→v51隔离覆盖安装、实际后台启动、重装及卸载通过。5019变量、31张画面、12张业务表、账号、图片、来源绑定、导航、批准设备证书和采暖季价格保持；工程业务文件字节及PG业务内容核对通过。维护日志与操作结果文件按原机制更新，未调用工程重置。隔离服务和端口已停止，原快捷方式已恢复。

Downloads已放完整EXE（236993215字节）、同签名APK（129215822字节）、KP接入资料ZIP、使用说明及SHA256。接入资料包含一次配置样例和画面打开/关闭脚本；无需增加中间服务或KP页面定时器。产物摘要、截图与保留验证见[release.json](evidence/20261106-v51/release.json)。

产品head的[Linux生命周期CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/42158594940)成功；[跨平台CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/42158595018)在交付核查时仍运行，已确认Linux/Windows Go及Android成功，其余结果不能沿用历史提交。PR61保持草稿；文档head结果单独核对。未部署现场或18153，未执行真实KP完整联调、安卓真机及原生Windows多窗口/DPI验收。结算数值问题仍为独立待办，本包未改结算逻辑。
