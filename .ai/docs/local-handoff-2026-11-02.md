# 本地接手交接 · 2026-11-02

## 当前执行状态

用户接手本地继续开发；本轮云端开发和每两小时主动汇报暂停。除完成此交接文档的推送与必要检查外，不继续新增工作。本次暂停不删除或永久关闭既有工作流规则；以后恢复需重新确认任务及仓库状态。唯一活跃看板仍为 [AI_BOARD.md](../../AI_BOARD.md)。

交接前已核远端 `main` 为 **`0ee59d2383e36cb615728eeb82a6bde0a17aa249`**，与最后功能验证提交一致。本交接批仅修改文档；拉取后以 `origin/main` 的实际 SHA 为准，不把文档提交误称为新的功能版本。

## 已合并成果

下列 PR #41–#51 均已合入 main，不是待合草稿：

| PR | 已交付范围 |
|---|---|
| [#41](https://github.com/YufeiSun5/universal-hmi/pull/41) | 传输提交等待期间保留结果窗口；提交异常回到映射并要求重新预览，不自动重复提交旧预览 |
| [#42](https://github.com/YufeiSun5/universal-hmi/pull/42) | 工艺编辑主保存、运行预览、工艺资料入口明确；素材区短高滚动布局 |
| [#43](https://github.com/YufeiSun5/universal-hmi/pull/43) | 导入/导出切换保留阶段、映射与查询上下文；更换文件取消不丢旧内容 |
| [#44](https://github.com/YufeiSun5/universal-hmi/pull/44) | 开发壳窄窗、长站名、账号操作及存储告警布局 |
| [#45](https://github.com/YufeiSun5/universal-hmi/pull/45) | 绘图工具与素材/属性面板明确折叠；保留未提交属性输入 |
| [#46](https://github.com/YufeiSun5/universal-hmi/pull/46) | 模板 JSON 与完整工艺包的分层往返语义回归 |
| [#47](https://github.com/YufeiSun5/universal-hmi/pull/47) | 导出成功/取消/失败反馈，剩余清单保存保护，传输弹窗桌面样式 |
| [#48](https://github.com/YufeiSun5/universal-hmi/pull/48) | 导出画面名称/站点搜索、显式已选数、跨站范围说明；筛选不丢勾选，在途选择不漂移 |
| [#49](https://github.com/YufeiSun5/universal-hmi/pull/49) | 仅修复原生文件成功测试的异步等待竞态，保留精确文件与反馈断言 |
| [#50](https://github.com/YufeiSun5/universal-hmi/pull/50) | 恢复设备 420×360 保存冲突、保草稿、一次重试与返回父界面的测试及说明 |
| [#51](https://github.com/YufeiSun5/universal-hmi/pull/51) | 导入变量按原键、显示名、文件来源站点检索，分页一致；不改变身份、映射或自动匹配规则 |

旧 `test/equipment-save-failure-layout` / `1432738118efeaba0c9e2eed663fb2aa9c88b20e` 的有效增量已由 #50 对齐主线并吸收，不再列为待实现。历史分支无需再次整批合并。

## 验证事实与边界

- 最后功能 main 的 [合后 Verify 41338422957](https://github.com/YufeiSun5/universal-hmi/actions/runs/41338422957) **attempt 2：10/10 成功**（3 Go、4 Flutter、3 安装包）。
- attempt 1 的 macOS DMG 校验曾报资源暂不可用；读取日志后仅该失败 job 单次重跑。新 job `124948214618` 明确通过 checksum/CRC 与 installer 验证，没有修改脚本或跳过校验。首次失败保留，不能写成首轮全绿。
- 最终 Flutter 本地 **457 通过 / 2 跳过**；analyze、Web release、专项与独立审查完成。两项专用 Chromium 下载测试因云端浏览器启动受限未执行，不能由 Web 构建或其他 CI 测试替代。Web“已发起下载”也不等于确认文件已落到用户磁盘。
- UI 证据为实际 Flutter 测试渲染器、合成数据，截图字体辅助只在测试侧使用；不是原生手工窗口、DPI/多屏、真实现场或真实设备验收。自动安装/更新/卸载夹具也不代替这些人工检查。
- `8147a0eb` 的 Linux 文件成功反馈测试曾失败；#49 修复等待实际保存任务的同步点，后续主线通过。既往失败或被后续运行取消的 CI 不追溯改记成功。
- [UI 验收说明](ui-layout-acceptance.md) 保留其历史时点及部分覆盖矩阵；[工艺往返验证](process-roundtrip-regressions.md) 明确模板故意清除实际绑定、完整包重映射引用和依赖的区别。两者都不宣称全部界面零缺陷或浏览器到生产后端的完整验收。

## 真正待办与兼容决策

1. **移动端/公网防护后续不是已交付成品。** [PR #28](https://github.com/YufeiSun5/universal-hmi/pull/28) 仍为未合并草稿，远端仅首 checkpoint `008ad7e5d00fd2f7c5e832bce6608e23d255a399`（记录/API 层）。其后续本地工作未上传，原临时环境已重置，不能从 main 或该分支拉取到；继续时需要重新实现、验证和审查，不能据旧完成描述直接启用移动 TLS/公网访问。
2. **WAF 仅隔离实验。** [ci/waf-compat](../../ci/waf-compat/README.md) 固定 Coraza 3.8.1 / CRS 4.30.0，独立模块与工作流使用 Go 1.27.3；未接入生产。产品工作流仍使用 Go 1.24.7，macOS 部署目标仍为 11.0。生产接入前需明确最低 macOS 与 Go 支持矩阵，不能默认将用户最低系统抬到 macOS 13，也不能为兼容回退到存在已知漏洞的旧依赖。具体版本和证据以模块锁及工作流为准。
3. 在可用本地环境补上述两项浏览器下载专项，并分别进行原生文件选择、DPI/多屏、GIS 真实地图及现场兼容验收；不要用测试占位图或合成数据替代。
4. 既往 ownership 测试快照竞态修正未合入；后续如复现需定位实际差异，不把新的 Go CI 成功当作该历史问题已修复，也不放宽业务断言。
5. 上线/升级是单独步骤：先备份并核对原工程、数据库、图片、来源和绑定；保留回滚路径。合并代码与构建成功不等于已部署，不能用合成测试工程覆盖原数据。

## 本地继续方式

先保存本地未提交工作，不执行强制重置；读取本文件、[AGENTS.md](../../AGENTS.md)、产品母本与相关模块规则。仓库内较早交接/记录是历史事实，不应覆盖这里的当前状态。

```sh
git status --short
git fetch origin
git log -1 --oneline origin/main
```

确认当前分支和本地改动后，再按自己的分支策略快进 main 或创建工作分支；不要重复初始化或整批合入历史 WIP。固定产品工具链为 Go 1.24.7、Flutter 3.35.4 / Dart 3.9.2，保留依赖锁；实际验证入口见 [验证说明](verification.md) 与 `.github/workflows/verify.yml`。

交接核查时本轮云端工作树没有未提交源码。SDK、缓存、临时截图和日志不作为源码交接的一部分；仓库更新不替代本地工程数据备份或安装产物交付。本次没有在用户电脑安装或执行命令。
