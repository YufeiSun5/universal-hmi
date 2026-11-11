# 当前在线与内网启动修正 v69

2026-11-10 用户要求开发模式查看当前连接数及具体在线人员，并反馈私有 IP HTTPS 上 Flutter 离线 Worker 注册遇到证书错误。

## 合同

开发端「登录与安全 → 当前在线」每10秒读取在线账号数、在线连接数和名单，显示用户名、入口、客户端类别、直连IP、登录时间和最近通信时间。同一登录会话共享的多个标签页合并计数；同账号独立登录分列，账号总数按稳定用户ID去重。这是近期通信的登录会话统计，不是底层TCP连接数，也不是历史登录记录。

identity记录内存在线时间，不改Session.Last用户活动时间、会话有效期或持久数据。已认证API请求记录通信；新客户端通过GET /api/v1/auth/presence每20秒报告，上一请求结束后再安排下一次，避免并发积压。超过90秒未通信移出名单；注销/撤销、账号停用/版本失效、设备证书失效或KP关联失效排除。暂停或休眠客户端恢复通信后重新显示。旧客户端长期仅保持SSE且无其他API时可能在90秒后不显示，升级后台后应刷新所有浏览器加载新客户端。

GET /api/v1/security/online仅有效、非只读且具有全站engineer开发权限的Actor可读，本机/授权内网开发入口可用。普通Web/KP/手机只可提交自己的已认证在线报告，不能读取全局名单。在线元数据无口令、会话令牌、CSRF或证书内容，IP仅取RemoteAddr，不信任转发头，客户端类别为User-Agent显示信息而非安全身份。

Flutter私有IPv4（10/8、172.16/12、192.168/16、127/8）、localhost、IPv6回环、非安全上下文及KP入口不注册离线Worker；正常公网域名HTTPS保留原逻辑。未更改TLS验证、证书或系统信任。该修复消除私有IP启动时的Worker注册尝试，不宣称解决HTTPS证书不受信任本身；内网免证书访问仍用已授权HTTP设置。

## 验证与交付

Go全量test/vet通过；Flutter analyze无问题、666项测试通过（2项既有跳过），UI检查器34项通过。专项覆盖权限、连接超时/注销/KP失效、在线页计数/名单/窄窗/失败撤旧结果及客户端报告生命周期。初次Flutter检查发现报告调度与测试异步完成时机问题，修正为串行定时报告、排除旧MFA未完成状态并等待异步结果，最终完整回归通过；未放宽权限或错误断言。

实际隔离后台通过正常登录API建立工程师和一个值班员的两个独立登录，真实Chrome展示2人/3连接；1440×900、760×620均可读。停掉一个模拟客户端的报告，90秒后名单自动降为2人/2连接，登录会话仍为3个。页面注入503后清空旧名单和人数，解除故障并刷新恢复。测试账号与数据均为隔离fixture，未操作现场账号。见[验证摘要](evidence/20261110-v69/verification.json)、[宽窗](evidence/20261110-v69/online-wide.png)、[窄窗](evidence/20261110-v69/online-narrow.png)、[超时移除](evidence/20261110-v69/online-after-timeout.png)和[UI检查](evidence/20261110-v69/ui-lint.json)。

自签测试证书的私有IP HTTPS页面加载v68实际bootstrap，复现同一ServiceWorker SecurityError与SSL错误；相同环境加载v69实际bootstrap，注册调用0次、相关console消息0条、Flutter renderer已加载。该探针只在匿名页面加载bootstrap验证启动，不替代正式认证验收，不安装系统证书、不改变生产TLS。Node回归覆盖18项KP脚本、7项提前加载、13项native/trial及内网HTTP/HTTPS与公网HTTPS条件；原Linux CI缺少secure-context fixture的问题已在测试夹具中修正。

Windows/Web均完成release与包内静态资源核验，本地源码摘要为`5c6ea81b4b785f7a76363feca677b3a67be62b5943af95244ce1a8fcbd1806cc`。完整安装包已交付。隔离浏览器与本轮HTTP/HTTPS服务已关闭，45827/48994无监听。

下载目录交付：`D:/Users/SunYufei/Downloads/Universal-HMI-20261110-Full-v69-Setup.exe`（268557213字节）、`v69-当前在线与内网启动-说明.txt`、`v69-SHA256.txt`。复制后摘要一致：`c1fb00121f98e36d09d9b14d84cf097d1e1e084c9aafb63d1c5d39a7269a50e5`。见[交付清单](evidence/20261110-v69/release.json)。包包含v67内网HTTP与v68接管绿色修正；服务器升级后浏览器刷新，无需导入新工艺配置。

接手核对v68 head d854a18：Windows/macOS后端、Android与Linux生命周期通过；Linux后端在KP脚本模拟步骤失败，Flutter及packages跳过。不据此宣称v69远端CI通过，本批最终head另行核查。

未部署现场/18153；安装覆盖/卸载矩阵及安卓APK不在本批重复执行。当前CI与本地结果分别记录，不沿用旧head作为通过证据。
