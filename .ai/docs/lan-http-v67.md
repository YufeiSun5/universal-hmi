# 内网免证书 HTTP 入口 v67

2026-11-10 用户在现场 172.16.1.10 实测 172.16.1.8:18443 TCP 可达，HTTPS 因 SEC_E_UNTRUSTED_ROOT 失败。用户要求内网不依赖客户端安装证书。本批增加内网 HTTP 访问，保留公网 HTTPS 和既有账号、权限、IP 白名单。

## 使用

升级后，在服务器开发端「登录与安全 → 网络入口」选择 HTTP（无需安装证书），保留内网 IP 和端口，保存并应用。已有工程的 HTTPS 配置不会在升级时自动切换。现场切换后的地址为 http://172.16.1.8:18443，其他内网电脑正常使用原账号登录，不再安装证书；客户端 IP 仍须在已有 Web 白名单中。HTTP 不加密，公网继续使用原 HTTPS 入口。

## 实现边界

networkaccess 管理 protocol、保存修订、实际监听和失败恢复。新配置默认 HTTP；旧配置未带 protocol 按 HTTPS 解释，旧客户端省略该字段时保留当前协议。HTTP 不生成或读取证书，HTTPS 仍校验证书。协议变更按同一 IP/端口停止旧监听、启动并验证新监听；失败按旧协议恢复，不结束其他程序。

server 仅在独立内网监听明确启用 LANHTTP，要求私有 IPv4 origin 和直连私有 IPv4 客户端，拒绝代理头。密码、验证码、白名单、CSRF、开发授权及本机管理边界保持。HTTP 会话使用独立名称 hmi_lan_identity、HttpOnly/SameSite Strict 与 lan:http:web/lan:http:engineering 通道，不与本机、公网或 HTTPS 工程师会话混用。公网仍强制 HTTPS、Secure Cookie 和原设备证书逻辑。

Flutter 网络设置显示协议选择和真实地址，仅 HTTPS 显示证书区。普通 HTTP 页面跳过需要安全上下文的 service worker，仍从同源加载前端和地图资源。

## 验证状态

Go 完整 test/vet 已通过；新增专项覆盖新旧协议配置、无证书 HTTP、同端口双向切换、HTTP 恢复、正常密码/验证码登录、Cookie 与会话隔离、CSRF、私网限制及非法配置拒绝。Flutter analyze、664 项完整测试通过，2 项既有跳过；Windows/Web 同源 release 构建通过。

真实 Chrome 访问隔离工程的私有 IP HTTP 入口，确认没有证书文件、非安全上下文下正常打开登录页；正常密码/验证码登录进入工作台，刷新后保持会话；工程师保存返回 201，缺 CSRF 和本机网络管理均返回 403。网络设置 1280×720、760×700 截图已检查，无证书设置要求。测试 Chrome 和隔离后台均已退出，监听端口已释放。

[结构化验证](evidence/20261110-v67/verification.json) · [HTTP 工作台](evidence/20261110-v67/http-engineering.png) · [网络设置](evidence/20261110-v67/network-http.png) · [窄屏设置](evidence/20261110-v67/network-narrow.png)

Windows 与 Web 源文件摘要一致：2354e5aa53ea65ba2b60e6815899bd3db0de0553528835786f4ac93801fb2802。打包过程中检测到重新生成的证书工具与构建初始清单不一致；逐文件核对变化仅为后端/打包工具后，用 package_desktop 生成并核验的实际清单同步 provenance，再通过完整最终包校验，没有修改校验规则。

未修改现场服务器、正式工程或 18153；本批未重跑安装覆盖/卸载矩阵，沿用既有保数据安装流程。实际现场升级、第二台物理电脑最终访问、远端 CI 单列，不以本机隔离结果替代。

## 本地交付

完整包 `Universal-HMI-20261110-Full-v67-Setup.exe`（268537414 字节）已复制到系统下载目录 `D:/Users/SunYufei/Downloads`，同时提供 `v67-内网免证书访问-操作说明.txt` 和 `v67-SHA256.txt`。复制后再次核对摘要一致：a844b5abb998fd529dab29ba6d4d57b57f499dc5625e0dc5bf6c487d9eef6a7e。[最终包证据](evidence/20261110-v67/release.json)。

包以工作区实际源文件摘要构建，构建基点 cadce8d，后续提交不重新标注历史构建基点。源码、架构与验证记录一起保存；远端 CI 不作为此次本地验收已通过的声明。
