# 权限配置入口移至最左侧（2026-10-27）

开发工作台原顶部“权限配置”移至最左活动栏底部，悬停提示名称；图标使用原管理账号图标。`main.dart` 将已有管理员判断及 `openSecurity` 回调交给 `WorkspaceActivityRail`；配置弹窗、后端鉴权、运行态入口和当前文档保持原行为，无接口或数据迁移。

Go test/vet、Flutter analyze及187项完整测试通过。隔离18157 Chrome在1367×770视口中确认入口位于x=5.5、y=704，尺寸33×44；顶部没有重复入口，点击打开账号与范围/登录会话/角色管理弹窗，关闭后回到原工作台。控制台无error/warn。未操作正式账号或刷新用户浏览器。

Windows/Web构建及封装通过，固定18153已更新（PID51580），源码摘要c9423598ba26b786e02fca918de831c3d256ac28363106e516517f351f7f891d。备份20261027-141527-password-policy；PG十一表数量与逻辑摘要一致，原1个账号及3份文档保留，在线Web字节与构建清单一致。详细结果记录于[部署核验](evidence/20261027-security-rail/deployment.json)。日志位于 `.local/security-rail-{go,analyze,test,web,windows,package}.log`。部署包为 `dist/Universal-HMI-SecurityRail-20261027`，复用原工程与PG数据库，既有桌面双入口指向新包，旧程序包可回滚。

远端最新[CI 38031925060](https://github.com/YufeiSun5/universal-hmi/actions/runs/38031925060)仍为旧提交f552d81c成功，不覆盖当前工作树。Windows构建不替代本轮原生鼠标/DPI验收，现场与公网不在本批。
