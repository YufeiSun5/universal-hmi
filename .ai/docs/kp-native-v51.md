# KP 对接与首屏加载 v51

本批为本地软件升级；验证和交付结果在完成后回填。产品母本为[agent.md](../../agent.md)，技术边界见[架构](architecture.md#kp原生令牌与gis首次加载2026-11-06实施中)。

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
