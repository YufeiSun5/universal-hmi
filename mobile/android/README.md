# Android 只读端

本机开发的原生 Android 8.0+ 安装应用，复用服务器现有只读 Web 界面。后端仍为 Go；不是手机内运行后台。设备使用安装专属 Android Keystore P-256 私钥，不读取 MAC、IMEI 或硬件唯一标识。卸载会丢失密钥，必须重新登记。硬件保护能力依手机而定，不声称已有硬件证明。

1. 本机管理员先创建账号和查看范围。
2. 手机导出公开授权资料，将其中 CSR 登记到该用户并审批，再在“手机证书授权”批准同一文件中的公开客户端证书。正式公开证书默认3650天（约10年），可在“更新本机公开证书”选1–36500天（最长约100年）；测试可单独选短期。证书截止时间须不晚于设备登记期限；本机登记默认约10年，按更长期证书授权时须相应延长登记。证书审批默认跟随证书截止时间，也可手动指定较短期限，更新后重新导出审批，私钥不变。登记和证书批准均有独立期限与撤销。
3. 手机填写 `https://固定IP:端口`，导入服务器公开叶证书并与管理员核对 SHA-256。IP、端口、证书以后可以更换；不内置现场地址。
4. 管理员在本机 `remote-access.json` 显式启用 `mobile_enabled` 和公网 HTTPS，按已有流程重启。只转发 HTTPS 只读端口；本机开发/管理端口不对外映射。
5. 手机登录账号、密码及 MFA 后查看。证书只解决设备认证，不替代用户权限。手机丢失时在本机撤销证书或停用登记。

原生远端连接显式 `Proxy.NO_PROXY`。服务器叶证书精确固定、有效期与 IP SAN 校验，设备 TLS 私钥证明，账号与设备归属及会话绑定由后端独立校验。WebView 没有原生 JavaScript 桥、文件/内容访问或外站导航。随机回环端口与随机 HttpOnly 会话只承载此应用；公网身份 cookie 保存在原生内存中，退出或进入后台时销毁。

构建：JDK 17、Android SDK 35 / Build Tools 35.0.0、Gradle 8.9、AGP 8.7.3，执行 `gradle --no-daemon testReleaseUnitTest assembleRelease`。签名由 `HMI_ANDROID_SIGNING_STORE` 与 `HMI_ANDROID_SIGNING_PASSWORD_FILE` 指定的本机文件提供，别名 `hmi-release`；未提供则只生成 unsigned APK。发布前须用 `apksigner verify --verbose --print-certs` 核验。签名密钥、密码、现场私钥、用户数据不纳入源码或发行包。未来更新 APK 必须保留同一签名身份。

JVM 单测覆盖客户端证书格式、严格只读路径、HTTPS 固定 IP 配置、真实回环 HTTP → mTLS、远端 cookie 隔离、错误 pin 拒绝和 SSE 首事件。JVM 使用软件测试密钥，不代表物理手机的 Android Keystore/WebView 或真实公网验收；这些须在用户安排后单独执行。

公网 Web/手机登录统一使用后端生成的5位数字图形验证码，2分钟内有效、一次提交即失效，点击图片刷新；不强制绑定验证器。图片码不替代手机设备私钥证明或Web IP白名单。

Android Keystore 安装密钥同时允许 SHA-256 证书签名和 TLS 需要的预哈希 NONEwithECDSA，启动时在真实密钥上预检；采用 `universal-hmi-installation-tls-v2` 别名，旧未发布USB测试密钥保留且不再选用。依据 Android 官方 KeyGenParameterSpec.Builder 的 setDigests 合同。服务器公开PEM证书也可存为 `.txt` 后通过系统文件选择器导入；只导入公开证书，不能导入服务器私钥。
