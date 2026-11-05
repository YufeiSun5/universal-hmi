# 移动端底部目录 v41

用户要求与架构分别见[产品母本](../../agent.md)和[架构](architecture.md)，当前状态见[看板](../../AI_BOARD.md)。

Android目录由左侧移至内容与底部主导航之间；搜索置于横向页签上方，展开/收起相邻。完整层级页内展开，搜索和行使用44px触摸尺寸；系统返回和页内返回先关闭完整目录。隐藏目录保留搜索、选择和已查询内容，半透明48px入口可拖动，旋转与窗口缩小时保持在内容边界内。

能耗复用历史目录组件，筛选已授权energy/comparison画面，取消画面下拉菜单。桌面继续侧栏，普通Web不因窗口窄自动启用安卓布局；查询中的站点与统计方式仍是业务筛选。无API、账号授权或数据算法变化。同期对比查询区按实际内容高度滚动，修复横屏覆盖底部目录的问题。

验证：Go全量test/vet通过；Flutter完整581通过/2个既有浏览器专用跳过；最终返回/触摸尺寸修订后导航、UI lint、页面树46项通过，横屏对比回归及原对比7项通过，最终analyze通过。首次完整测试发现搜索点击尺寸、间距及空目录文案回归，均修复，未放宽业务断言。v40远端Verify 41952448708的history_filter_race_test.dart格式失败已本地修正。中间构建因开发期间源码变化被一致性门禁拒绝，不作为最终产物。

Chrome真实触摸输入已检查页面切换、搜索、隐藏恢复、拖动不误展开。浏览器使用本机隔离SQL2017合成数据；该夹具未安装能耗当前统计专用过程，能耗查询失败被正常显示，不视为现场能耗故障或成功证据。没有连接可调试手机，不称安卓真机验收。按用户指示不继续排查现场9090网络，不更新18153或现场安装。

最终Windows/Web release均通过，源码摘要一致为`2ce0bf7bd0a61a3fda05a67f59beaaa94d524fc5f4beb741b3ea02ccfe93e924`。最终Chrome触摸会话未记录pageerror；目录显隐请求计数为0，普通Web 1440×900保持左侧目录。390×844及844×390截图、日志和检查清单见[本批证据](evidence/20261105-v41/verification.json)。产品436fede的[Linux生命周期](https://github.com/YufeiSun5/universal-hmi/actions/runs/41957716825)成功，[跨平台Verify](https://github.com/YufeiSun5/universal-hmi/actions/runs/41957716648)在记录时仍运行，不能宣称全绿。代码位于[PR56](https://github.com/YufeiSun5/universal-hmi/pull/56)，叠加PR55，保持草稿；截图评审交付不等于新安装包或现场部署。本批未制作EXE安装器或APK。

截图：[底部目录](evidence/20261105-v41/history-directory.png)、[完整目录](evidence/20261105-v41/history-expanded.png)、[拖动入口](evidence/20261105-v41/history-hidden-dragged.png)、[保留搜索](evidence/20261105-v41/search-retained.png)、[能耗目录](evidence/20261105-v41/energy-directory.png)、[横屏](evidence/20261105-v41/energy-landscape.png)、[桌面](evidence/20261105-v41/desktop-history.png)。
