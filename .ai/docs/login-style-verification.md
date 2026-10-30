# 庄河参考登录界面验证

日期：2026-10-27。用户要求登录画面参考本机庄河 HTML 的登录页。

## 实施范围

- 参考 `D:/DEV_D/ZhuangHe16/庄河HTML/pages/login/index.html`、`page.css` 与共享主题。沿用该项目既有生成背景图，逐字复制至 `app/assets/login/`，保留原生成提示和来源说明；此图为沿海供热意象，不是实地地图。
- `app/lib/features/login.dart` 负责原有表单与提交；`login_style.dart` 提供登录专用主题、背景和面板。宽屏右侧440px面板，窄屏居中，低高度窗口可纵向滚动；密码显隐、忘记密码说明、图标输入与青蓝按钮。
- 保留本系统首次建号、后端密码长度、验证码/恢复码、过期提示、密码清空、错误反馈和提交互斥。未迁入参考项目的调试面板、宿主登录接口或账号限制；未改变Go身份、权限或数据库契约。

## 本批验证

- Go `test ./...`、`vet ./...`：passed；Flutter analyze与完整193项测试：passed。包含错误/正确登录、重复提交、密码清空、会话撤销、MFA引导、首次密码规则及320px窄屏回归。
- Windows/Web release：passed，同源摘要 `7d3f2694f8edf29515db4404819b515fa1e40c2150ba43f4cb91bceffdab9ded`。
- 独立18157空工程及独立Chrome上下文：实际表单创建测试账号、Enter提交、退出、普通正确/错误密码登录、显隐切换、忘记密码提示通过；未使用原工程账号或凭据。
- 浏览器1367×770、360×640和360×400通过；低高度滚动后登录按钮与帮助提示可操作。截图：[宽屏](evidence/20261027-login-style/login-wide.png)、[窄屏](evidence/20261027-login-style/login-narrow.png)。重新加载后无控制台error/warn；自动化工具合成组合键期间出现Flutter键位location映射错误，定位于生成JS的键盘适配，未作为产品登录故障隐去。错误密码请求返回401符合预期。
- 本次未另做Windows原生鼠标/DPI验收，构建不代替原生人工验证。未连接现场。
- 远端基点f552d81cece70a3bc7f4287b228e15bbdd6c2108的CI 38031925059与38031925060均success；该历史CI不覆盖本批未提交工作树。

## 固定入口部署

固定18153及桌面双入口已升级至 `dist/Universal-HMI-LoginStyle-20261027`，实际服务静态文件与新包摘要一致。升级前备份 `20261027-152345-password-policy` 包含PG、身份密钥、外部连接密钥和旧启动配置；升级后PG十一表数量与逻辑摘要一致，原1账号、4站点、3文档不变。旧包及回滚配置保留，用户原浏览器未刷新；独立测试服务和浏览器已关闭。见[部署记录](evidence/20261027-login-style/deployment.json)与[浏览器记录](evidence/20261027-login-style/browser.json)。
