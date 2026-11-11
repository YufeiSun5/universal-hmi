# KP 与普通网页登录共存修复 v74

现场KP刚打开即提示关联已失效，runtime/events、runtime及screens返回401，响应为authentication_required/凭据无效。该文本来自IdentityHandler在同时收到身份Cookie与Authorization（或Authorization格式不合法）时的拒绝分支。现有KP客户端发送合法Bearer，浏览器自动附带同源普通Web Cookie；隔离已复现完全相同错误。现场请求头未收集，不宣称完成现场网络捕获。

## 修复范围

backend/internal/server/identity.go仅对公共入口中经过identity.KPTokenValid校验的KP关联Bearer允许优先使用。保持账号状态/版本、关联租约、撤销、设备绑定、Origin、权限和公共写入边界。把冲突身份Cookie从内部请求副本移除，使下游外站能力也使用KP身份；其他Cookie及原请求头保持，不修改浏览器登录Cookie或普通Web会话。

正式KP与联调均适用。普通密码Bearer+Cookie、伪造Bearer、错误Authorization仍拒绝；KP失效后不回退到Cookie账号。前端未改，不要求重配KP身份或重新导入变量/总览。

## 验证

新增回归在修复前正式/联调两模式都重现同一401；修复后KP无Cookie、有效Cookie、过期Cookie均通过，另一个账号Cookie不改变KP实际Actor。错误/普通混合凭据拒绝，KP撤销后不能回退且原Web会话仍有效。

扩展既有native KP整链路测试与真实main隔离TLS/WAF启动测试。使用HTTP CookieJar模拟浏览器自动携带身份Cookie，正常API建立测试账号和配置KP，经模拟可信上游核验、兑换后，runtime、screens、外站能力及SSE首次数据通过；关闭后撤销和写权限边界保持。最初仅调整认证选择时发现外站能力还会读取Cookie，已在认证边界统一内部请求身份并复验。

首次Go全量测试中既有在线运维web-cookie用例的随机CSR提交被WAF拒绝；单独复测原断言通过，未修改该测试或WAF规则。最终Go 1.24.7全量test/vet均通过。旧外站测试曾将所有混合凭据一律断言拒绝；已明确只允许有效KP关联身份并核对外站能力归属，普通/伪造混合凭据拒绝断言保持。Windows/Web同源构建和完整EXE封装通过。

未改现场/18153，没有真实KP现场认证复测。Flutter源码未改，本轮不重复全套前端测试及安装覆盖/卸载矩阵；Windows/Web同源封装另验。用户要求不输出压缩包，只交EXE、说明及摘要。

[修复前复现](evidence/20261111-v74/red.log) · [真实HTTPS/WAF与专项](evidence/20261111-v74/integration-final.log) · [Go全量](evidence/20261111-v74/go-test-complete.log) · [test/vet退出结果](evidence/20261111-v74/go-result.json)

## 交付

应用提交`fba209ac45e9d490ac6130992c707fa29537f9a2`；源码摘要`2b797c92702a00f9c75b74b6eb930b8e4b828ed674702de44872963f664abbd4`。Downloads中提供`Universal-HMI-20261111-Full-v74-Setup.exe`（268617418字节）、`v74-KP登录关联失效修复-说明.txt`及`v74-SHA256.txt`。SHA256：`4526f2114d77ef77577270301a32a22056f2225520dd9db0c24367e0ca17d82a`。没有对外输出压缩包。

[交付清单](evidence/20261111-v74/release.json) · [验证摘要](evidence/20261111-v74/verification.json)。服务器覆盖升级原位置、保留原工程，后台重启后重新打开KP建立新关联；正式模式不用修改脚本或映射，联调模式重启后的授权轮换按既有流程处理。无需重导变量/画面/总览。

应用提交的Linux生命周期[42978441390](https://github.com/YufeiSun5/universal-hmi/actions/runs/42978441390)已success；跨平台[42978441406](https://github.com/YufeiSun5/universal-hmi/actions/runs/42978441406)交付时仍在运行，不声明全部CI通过。[状态快照](evidence/20261111-v74/ci.json)。安装EXE文件及产品版本均读回为0.1.0.74。
