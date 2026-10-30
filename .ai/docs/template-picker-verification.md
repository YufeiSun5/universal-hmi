# 添加画面的工艺图模板选择（2026-10-27）

用户要求未来模板增多时，先选画面类型，再在独立表单选择工艺图模板。母本为 [agent.md](../../agent.md)，契约为 [architecture.md](architecture.md#站点先建与公共工艺布局2026-10-27)。

类型下拉只保留工艺图、GIS地图。工艺图下提供公共画面/内置模板分类、关键字搜索、虚拟列表、选中图预览和名称；内置目录统一在 `ProcessTemplates.catalog` 扩展。公共画面引用继续同步布局、本站独立绑定；内置模板创建独立文档。没有新增后端接口或更改权限、数据归属。异步预览只接受最后一次选择，创建公共引用时重新读源版本；用户手填名称不随模板切换覆盖。空列表与读取失败可见，并提供重试。

弹窗宽窗口左右排列、窄窗口上下排列和滚动。实际验证发现资源侧栏在窗口变窄后会被卸载，使旧创建回调丢失；现在主工作台持有创建回调，侧栏重建后仍能添加并打开画面。

已通过：Go全量test/vet；Flutter analyze无问题；187项全量测试，以及最终回调修正后的17项回归；Windows/Web release和同源清单校验。测试覆盖120项模板搜索定位、公共源最新版本引用、内置/GIS身份隔离、名称保留、过期预览不覆盖、小弹窗和侧栏卸载后的自动打开。初次Go检查受系统GOROOT指向1.25.5影响，设置固定1.24.7后通过；初次Flutter检查发现旧测试定位器、弹窗固有尺寸计算问题，修正后通过。

隔离18157 Chrome实测分类/搜索/两种模板预览、手填名称保留、内置独立创建、公共引用创建；1367×770与640×360弹窗操作和缩放后自动打开通过，最终控制台无error/warn。新版本复测前清除了该隔离浏览器的旧Service Worker缓存；用户浏览器未刷新。640×360仅证明本对话框可操作，不宣称整个开发工作台在该宽度无裁切；全工作台断点回归使用779px跨越780px侧栏边界，极窄工具栏仍属桌面体验后续范围。

本地记录：`.local/template-go.log`、`template-all-tests.log`、`template-final-focused.log`、`template-analyze-final.log`、`template-build-web-final.log`、`template-build-windows-final.log`、`template-package.log`。远端最新CI仍为旧提交f552d81c的[38031925060](https://github.com/YufeiSun5/universal-hmi/actions/runs/38031925060)，success，不覆盖本批未提交工作树。Windows构建不替代本轮原生鼠标/DPI验收；现场设备、公网和容量优化不在本批。

固定18153已升级，PID71612，程序部署目录为 `dist/Universal-HMI-Templates-20261027`。升级前备份为 `.local/postgres/backups/20261027-140704-password-policy`（沿用备份脚本历史命名）；PG十一表数量与逻辑摘要全部一致，保留1个账号、4个站点身份及3份文档，在线Web字节与构建清单一致。保留原工程、PostgreSQL配置及既有桌面双入口，旧程序包可回滚。源码摘要 `c5cfab7e62e7c88c6d88820b80b4222775c35d3df70522d0e49fc4700fdedb26`；详细结果见 [部署核验](evidence/20261027-template-picker/deployment.json)。
