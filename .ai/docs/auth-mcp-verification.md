# 登录与 MCP 专项验收（2026-10-02）

## 起点与范围

基点：`7d64aefe86f1ffbae7beb76761cea127d8c6f45a`。该版本无登录/会话/MCP，命令行仅允许回环监听；不能将之前主功能已通过的测试作为登录成功证据。

本轮实现：单用户、操作者准备 bcrypt 账号配置；认证模式实际 TLS 与精确 Host/Origin；cookie/短期 bearer、CSRF、退出/绝对过期、只读权限；Flutter 登录/注销/过期恢复；32 个 MCP 工具覆盖全部现有业务 REST 操作，沿用业务校验与受控动作。没有部署实际内网服务或创建真实账号/持久访问。

合同及使用限制：[认证](intranet-auth.md)、[MCP覆盖](mcp-coverage.md)。第三方 OAuth-only MCP 客户端不在兼容承诺内。

## 独立复核发现及回归

1. HTTPS MCP 内部分发丢失 TLS 元数据，合法 Origin 被视为跨域：保留实际传输元数据，并以真实 TLS loopback + cookie/CSRF 验证写操作。
2. 本机无认证 MCP 接受攻击者匹配的 Host/Origin，可 DNS rebinding：本机入口限制 localhost/字面量回环 Host，明确拒绝转发头替代与恶意 Host；认证模式仍精确公共 Host。
3. 只读 REST 的规则/导入预览被方法级写限制误拒：仅明确两个 POST 预览入口为只读，认证与 CSRF 继续强制。
4. MCP 已知工具参数校验错误和 HTTP200 的规则校验错误没有正确标为工具失败：按固定协议区分信封/工具错误，不能把预览未知质量误判为错误。
5. 浏览器多标签旋转 cookie 后，旧 CSRF 导致写入及退出一直失败：仅显式 `csrf_rejected` 使旧工作区退役，不重试修改；普通权限403保持权限错误。

复核中还补上大整数结果不经 float64 转换、内部路径身份转义、响应/文件/并发上限、规则多步日志异步等待与窄屏登录布局。

## 已通过验证

产品 head `32607c71b3823f562e9a5cc213b35ccf72416bb4`、tree `9047c6e7fc238a75256350557ca939845f787146`，远端 Git tree 与本地暂存源码逐字一致；[PR #10](https://github.com/YufeiSun5/universal-hmi/pull/10)。后续修正仅让手动 CUA 入口在运行时读取隔离 fixture URL/CA，未改变生产 main 或认证/MCP业务代码。最终 head CI 必须在同一 PR 查看，不能将初始 head 的绿灯直接当成后续提交通过。

- 本地 Go1.24.7：`go test -mod=readonly -race -json ./...`，118 个顶层测试/265 个含子测试通过；仅手动 CUA fixture 在常规套件中按设计跳过。真实本地 MQTT 用例没有跳过。vet、module verify、只读 gofmt、server build 通过
- Flutter3.35.4 / Dart3.9.2：锁定依赖、格式、analyze、76 个单元/widget测试全部通过；其中21个认证测试覆盖错密/正确/重复提交、退出、过期、上传下载、旧响应/旧工作区隔离及 CSRF 轮换
- 生产 Linux release 与 Web release 构建通过；实际 CUA 使用另行编译的测试入口，不能把它当生产包。13个发布门禁、5个进程、10个字体 Python 测试通过
- 独立复核：auth/MCP/Origin race、原始 DNS rebinding 和规则假成功 overlay 重现回归通过；最终产品 head 未发现剩余阻塞
- 初始产品 head 完整 [CI37010627839](https://github.com/YufeiSun5/universal-hmi/actions/runs/37010627839) 六项成功，包含 Go Linux/Windows、Flutter Linux/Web/Windows、最终组包；[生命周期37010628064](https://github.com/YufeiSun5/universal-hmi/actions/runs/37010628064)成功
- 实际原生 CUA：错密拒绝且不进工作区、正确登录、主动退出、重新登录、约60秒绝对过期、过期后再次登录均通过。13:18:44 UTC打开新增点位弹窗未保存；13:19:37 UTC过期后弹窗/工作区全部消失，仅保留登录页。正常 Alt+F4 关闭退出0，fixture测试302.16秒 PASS并完成清理
- 同一桌面进程网络环境的 Dart TLS 检查：仅显式fixture CA信任时成功；默认系统信任拒绝自签证书；即使信任该CA，错误主机名仍拒绝。没有 badCertificateCallback、全局信任修改或浏览器警告绕过

机读摘要：[本地检查](evidence/20261002-auth-mcp/local-validation.json)、[原生TLS](evidence/20261002-auth-mcp/native-tls-validation.json)、[原生CUA](evidence/20261002-auth-mcp/native-cua-validation.json)。测试口令不保存在报告中。

最初从工具执行环境启动的 fixture 无法从桌面访问（网络与/tmp隔离），未计入成功证据；已终止。实际通过的 fixture 由桌面终端启动，证书和数据位于该消费者可见的隔离目录，应用关闭后自动停止。

## 验证纪律

Go 单元/真实本地 MQTT、Flutter widget、实际原生 CUA 与现场部署分别记录，不互相替代。手动 CUA fixture 默认跳过，仅显式启动时运行；使用独立临时数据、仅回环 TLS、进程内信任合成公开证书，无全局证书信任修改，也不绕过浏览器警告。

没有现场设备、Windows 真机交互、生产部署或长期安全渗透验收；不得据此称生产安全已完成。
