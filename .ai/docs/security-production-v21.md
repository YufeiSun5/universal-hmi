# 生产覆盖升级 v21 · 2026-11-02

本轮是在原工程上的覆盖升级；原Windows账号、安装AppId、工程目录、数据库、密钥及9090映射保持。先退出两端并停止后台，完整备份project目录，再覆盖安装。安装不调用Reset，不导入交付资料、不连接现场；运行中拒绝覆盖。回退先停止两端/后台，保留失败现场，再恢复升级前完整project及对应旧程序。

## 本批实现

- 公网Web/安卓只读、后端图形验证码、真实设备私钥认证、首次正确登录申请和本机一次批准、长期可撤销设备授权。
- Coraza/OWASP请求规则、限流、自动封禁、持久审计；本机白名单、用户/设备审批与撤销、手动封禁和解封。自动封禁不会缩短人工封禁。
- 开发态、运行态、Web/手机查看访问与拦截记录；普通账号只查询自身已认证记录，具有安全/全局审计权限的账号可只读查询全局。公网无管理写入口。
- 七维科技与沈阳波尔独立顶部菜单。Windows WebView2、Web同一HTTPS端口的opaque沙箱网关；分别保持供应商会话，服务器过期仍须登录。Android外站Cookie单独原生加密保存，HMI身份不持久化。
- 原生启动窗独立STA动画、当前启动阶段与计时，NoUI/Stop不显示。

## 已有本批证据

Go全量test/vet通过；Flutter analyze、468项通过/2浏览器跳过，窄窗及本机管理原入口回归已修复；Android7 JVM测试、lint和签名release通过。启动窗真实Windows PowerShell5.1编译/显示/关闭通过。

真实Chrome在隔离HTTPS入口中显示两外站登录页；供应商脚本的通用替换破坏及旧frame-buster问题已定位并修复。opaque双层fixture验证XHR携带自身Cookie且不能读主系统DOM，持久profile重开后Cookie保持。无供应商账号，未宣称登录后的未知功能或永久免登录已验收。开发机Fake-IP被生产网关拒绝；实测仅将两固定外站的当次真实公网解析用于隔离transport，未更改系统DNS/代理。

v19→v21完整安装器隔离覆盖、原账号登录、5019点/31画面/11表、来源/绑定/导航、设备资料与图片保持通过；安装及重复安装均不改工程文件。完整冷备恢复后，逐表核对与备份一致，账号和原安全配置可用。运行中覆盖被安装器拒绝，程序文件未变。隔离卸载保留工程，注册移除、原快捷方式恢复、端口停止已确认。全新PG、历史迁移、原库/备份字节保持、端口冲突拒绝、坏资料失败闭锁及修复重试均通过。

本轮测试曾因旧夹具已含验证行而触发计数断言，改用独立干净夹具后通过，原参考库和程序未改；冷备核对使用实际备份时的11表摘要，区分升级后正常登录新增的审计记录。辅助恢复脚本加载分隔符修正后完成实测。失败记录保留在本机测试日志，不把测试错误写成生产故障。

交付产品提交`dd640c63d3c92bc55830f5b2275d8bb789183464`，应用源摘要`4be232ee29a9b9747441b2047c960a48e2d0f388ae5d6d74fe513ffad8393d91`。源码冻结后Windows/Web重新构建；清除增量目录遗留的旧Go辅助程序再生成一致产物清单，封装包含PG18.6。后续证据文档提交不改变该应用源摘要。

| 交付文件 | 大小与SHA256 |
| --- | --- |
| [完整覆盖安装器](../../dist/installers/full-20261102-v21/Universal-HMI-20261102-Full-v21-Setup.exe) | 234326454字节；`9c4678917336c1b8d69f484beb139869622bd1a5d828f43e35b124dee94f2368` |
| [Android正式APK](../../dist/installers/full-20261102-v21/Universal-HMI-Android-v21-20261102.apk) | 86068字节；`c48120da606e50375518b1ea76452bb4e009a8b64bcf2520cbe1ad4030173546` |

Android版本21/0.1.0.21，固定发布证书摘要`97247b52d1b26718619999c4c7fd4b308b8f50418079b954ba1e6faa132cf80c`。Moto Android16真实USB覆盖安装成功，原Keystore公钥及服务器证书保持，正式版无debuggable标志且WebView调试关闭。手机保留短期本地测试配置；现场服务部署后再切换地址和正式长期证书，不把该测试证书当生产证书。

[安装升级](evidence/20261102-production-v21/installer-upgrade.json)、[冷备恢复与运行中拒绝](evidence/20261102-production-v21/cold-restore.json)、[PG启动迁移](evidence/20261102-production-v21/postgres-launcher.json)、[产物与范围](evidence/20261102-production-v21/release.json)分别计证。实际Chrome截图保留于本机`output/playwright/external-v21/embedded-final.png`。

本批产品提交dd640c6的[CI 41390294232](https://github.com/YufeiSun5/universal-hmi/actions/runs/41390294232)已完成，11项全部成功：三平台Go含race、四平台Flutter、Android和三平台完整包；[Linux生命周期41390294231](https://github.com/YufeiSun5/universal-hmi/actions/runs/41390294231)也已成功。PR53保留草稿，等待最终文档head的CI和审查；旧批次成功不代替本批，证据文档提交不改变交付应用源摘要。

现场公网地址、18153和真实工程未连接或改写。现场端口隔离、真实白名单、设备审批/撤销、异常封禁和备份恢复仍需在实际部署完成后验收，不能用本机结果代替。
