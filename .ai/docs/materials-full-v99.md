# v99 请购、出入库与二网合计完整安装包

2026-11-16，用户要求将当前已完成的功能打成安装包。沿用保留数据的完整Windows EXE，包含离线Web资源与私有PostgreSQL18.6；不自动部署现场或更新18153/21317。

## 包含功能

- [v97请购](materials-requisition-v97.md)：编制、审核、批准、物资已阅，个人签名、原稿与复核、按工程编号搜索；闭环后单张/批量导出，原稿式独立签名格，可重新导入。
- [v98出入库](material-documents-v98.md)：收料/领料模板，同类勾选单据在一个工作表纵向排列，明细扩展和后续区域下移；缺失字段与未签岗位留空。
- [工艺目录与开发入口](process-loading-investigation-20261116.md)：后端目录/导航只读元数据、重复目标复用；Flutter开发入口映射和菜单失败时可读目录保留。实际开图与权限校验保持。包含v96 Hotfix1后端修复，不代表现场TLS根因已最终确认。
- [东南区双表合计](secondary-meter-v99.md)：FE201+FE202四项在小时/日报只显示合计，曲线热量同步合计，共用温压保持；瞬时量按同步采样先加后取极值，累计量相加原时段用量，缺组留空。

## 来源与验证

初始封装仅修改安装器版本和发布说明，产品代码与40752d9e一致；随后用户追加[东南区双表合计](secondary-meter-v99.md)，最终包须包含该新增修复。新增后Go全test/vet与Flutter813通过2既有跳过/analyze通过，最终构建与校验另记。

未交付的内部候选源码eeebf6cc，版本0.1.0.99，Windows/Web摘要`f9141c8c8e0fca0661d8dab89415f3606a9404a93915df7ea4fccf5b21ca3eef`；该候选不含新增双表合计，不能当作最终包。候选已完成正常登录、请购和出入库单张/批量导出、库存未变及完整EXE校验，EXE摘要`1dd1ce480914839aab6f5e942bf1aa59d5dca1f66fac810e8c351ba0ed70b08f`，只保留本地证据。

最终包已于2026-11-16本地交付，源码`1ecbe4cb0ce0627903274b364d66aef3ee6478c7`，Windows/Web同源摘要`401ab56f34680c0bf874d87b4837bb341277262a0449b573c132cf56b8cf9808`。完整EXE为287,688,590字节，SHA256 `56b3e4b288ea737ab0f2c5fd2eb3e8c949ef6a512af60581ff68bdb7ec4fac9d`，位于本机Downloads的`请购出入库与二网合计_v99_20261116`目录，无ZIP。

最终Go全test/vet、Flutter813通过2既有跳过/analyze、Windows/Web构建和封装全部通过。最终包内后端正常登录、五种物料Excel单张/批量导出及库存未变通过。实际Chrome连接隔离SQL，验证小时四合计、完整日报、部分日报标识、缺测提示、CSV实际下载以及重点曲线24个小时均为11的合计系列，1440/800宽度截图已检查，控制台0错误/0警告。日范围较长标注沿用既有单元格适应宽度，完整语义保留于导出。测试API、SQL容器和专用浏览器均已关闭。

证据见[交付核验](evidence/20261116-materials-secondary-v99/release-verification.json)、[包内物料导出](evidence/20261116-materials-secondary-v99/smoke-result.json)、[安装包清单](evidence/20261116-materials-secondary-v99/installer-manifest.json)和同目录截图/日志。SQL原始查询是真实执行；累计统计过程使用符合现有契约的隔离fixture，不代表现场数据库结算引擎已验。未重跑安装/卸载矩阵、原生DPI、真实KP或现场验证，不将编译成功当作这些项目通过。

远端[PR74](https://github.com/YufeiSun5/universal-hmi/pull/74)保留草稿；源码1ecbe4cb核对时Linux生命周期、Go Linux/Windows和Android成功，Go macOS仍在途，Flutter多端后续任务尚未完成。远端CI与本地Windows/Web交付分别记录；此前PR72/73成功不替代本批检查。

## 安装

关闭客户端并停止后台，完整备份原工程（数据库、objects、equipment/photos及账号/安全配置），覆盖安装原位置并继续使用原工程；不要先卸载或重新导入画面。升级后启动原入口验证。回退须恢复对应旧版的完整工程备份。
