# 内网 HTTP 外站嵌入登录 v89

2026-11-14 用户要求修复七维科技、沈阳波尔的内网页内登录，测试通过后提供完整独立安装EXE，不改现场配置。用户另提供两个真实账号授权登录验收；账号与密码不写入源码、证据或安装包。

## 范围与原因

内网 HTTP 使用 hmi_lan_identity 与独立会话通道，原外站元数据仅处理 HTTPS 公网身份，导致七维直连沙箱、波尔回退新标签。两供应商真实脚本均试图跳出iframe。七维URL重写会话参数还可能进入ctx后拼出错误登录路径；波尔登录后的相对初始化地址和JSON菜单根地址会逃出代理命名空间。

修改仅在 backend/internal/server/external_sites.go、backend/cmd/server/main.go 及相关测试和包装版本。内网HTTP由独立网关签发受控能力，后端内存jar隔离两站/两个监控登录会话；保留既有准入、身份通道、撤销、固定上游和opaque沙箱。兼容路径和菜单不扩成通用任意站点代理。七维登录表单原 margin-left:100% 在1366宽嵌入区域会溢出，增加仅该登录表单的窄窗位置适配。Flutter源码不变，现有metadata sandboxed协议自动使用双层iframe。

## 验证记录

- 最终源码120b790e：Go全量 `go test -mod=readonly ./...` 与 `go vet -mod=readonly ./...` 通过。覆盖内网运行/开发通道、正常身份/验证码/IP准入、两会话与两供应商Cookie隔离、路径/删除/退出、来源与通道拒绝、七维ctx、波尔导航/菜单/信号图标地址。Windows/Web release同源码构建与组包核对通过。Flutter源码未改，本轮未重跑其全量单测。
- 隔离Chrome实际在私有IPv4 HTTP上经正常监控登录API、验证码、IP准入、WAF与双层opaque iframe访问两站。合成供应商验证错误重试、登录POST、Cookie轮换、成功跳转、切页重开、供应商退出、监控退出后两能力401；两监控会话/两供应商jar隔离、Cookie路径与删除、跨来源/通道拒绝有后端回归。
- 真实账号：七维登录后进入index及内层sysPersonalization，温度/设备统计可见；波尔登录后菜单与实时列表可见，首屏20行。两站切换/重开保持登录，主监控页面未被跳走，供应商无法读取顶层DOM。未执行设备/参数/人员/企业配置修改。
- 本机FlClash将两域名解析为198.19.x，生产固定公网拨号策略仍拒绝该地址。真实供应商浏览器验收只在opt-in测试夹具内使用系统正常transport连接两个固定供应商；没有改系统DNS/代理、现场配置或生产拨号策略。夹具只放行GET/HEAD、两个登录POST与波尔菜单/实时列表只读POST。正式包的独立入口装配和构建另验；不把此transport替代说成现场网络已验。
- 正式后端二进制在新建隔离工程经正常账号/验证码登录内网HTTP成功，两个metadata地址均为受控代理且sandboxed=true；正式Flutter Web两入口都生成双层opaque iframe，页面无JS错误。正式拨号在本机Fake-IP环境返回502，未冒称正式网络端到端通过。
- 波尔列表动态生成的信号图标地址最后补齐命名空间重写，新增后端回归通过；该最后增量未另重跑真实账号业务浏览器流程。登录/首屏浏览器证据来自同轮此前修复后的代码。
- 真实供应商截图仅留本机.local测试目录，不提交公开仓库或随包分发；仓库仅保存去凭据结果。全部测试浏览器和本轮隔离HTTP实例已关闭，未执行设备/业务配置写入。

本轮未部署现场/18153，未重跑安装覆盖/重装/卸载矩阵、Windows原生WebView2交互或手机真机。供应商完整业务操作不在本次验收范围。账号密码不随包提供。

## 交付状态

完整Windows/Web同源码构建及组包核对通过，安装器0.1.0.89已交付到 `D:/Users/SunYufei/Downloads/内网外站登录修复_v89_20261114`。完整独立EXE、说明、验收结果与SHA256齐，无ZIP。安装器保留已有工程，不调用重建；包含离线PostgreSQL18.6，沿用既有WebView2前置要求。源码 `120b790e5d33b850ee4b798ba897ea25228864ea`；包内后端与实际启动隔离验证的二进制SHA一致，Web主文件也一致。

安装器SHA256：`c70b877d7a40a2c7963384f2d9bcce7f438cc23ae2eacecb58c8d50e96a6121d`；大小 284967289 字节。下载目录副本再次计算SHA一致。未运行安装器或部署现场/18153。

[PR #64](https://github.com/YufeiSun5/universal-hmi/pull/64)保留草稿；核对时跨平台CI尚在进行，不能把本地成功视作所有远端门禁通过。后续文档提交不改变本包代码指纹；CI快照以对应head为准。

证据：[模拟浏览器](evidence/20261114-external-lan-v89/browser-result.json)、[真实账号浏览器](evidence/20261114-external-lan-v89/live-browser-result.json)、[正式后端API](evidence/20261114-external-lan-v89/final-api-result.json)、[正式Web装配](evidence/20261114-external-lan-v89/final-ui-result.json)、[Go测试](evidence/20261114-external-lan-v89/go-test.log)、[Go vet](evidence/20261114-external-lan-v89/go-vet.log)、[发布结果](evidence/20261114-external-lan-v89/release-result.json)、[CI快照](evidence/20261114-external-lan-v89/ci-summary.json)。
