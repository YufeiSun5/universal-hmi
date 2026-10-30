# 工艺框选与箭头动画 v15

用户要求工艺图框选多选，并明确手动开启箭头和动画后仍不流动。本轮由Terra实现框选，Sol修复动画并发行，root审查与实际界面验收。母本为[agent.md](../../agent.md)，状态以[看板](../../AI_BOARD.md)为准。既有18153工程、现场及MQTT配置不在本批操作范围内。

## 实现与审查

`ProcessController`维护编辑态选择集合；`ProcessCanvas`在选择工具下从空白拖动框选，Shift追加框选/切换单项，Ctrl+A全选。空间坐标转换使用原缩放和平移参数；中键、空格拖动及手形工具继续平移。多选可整体移动、复制、删除，每次文档操作只需一次撤销；复制重映射组内管线连接，组外连接固定为原解析端点。多选属性面板显示数量和批量操作，元素属性仍须单选编辑。

root发现初版空白命中先于外侧缩放手柄，已退回修复；最终单选手柄和管线顶点优先，新增外侧5px/8px回归。没有通用locked属性，沿用现有隐藏背景排除逻辑，不虚构锁定能力。多选右键禁用仅支持单对象的层级命令。

箭头可复现问题位于`pipe_flow.dart`：原`state.moving && !MediaQuery.disableAnimationsOf(context)`使系统关闭界面动效时，手动开启的业务流动也永远停止。已改为由箭头开关和有效条件决定，AnimationBehavior.preserve保持设定速度；TickerMode隐藏页暂停仍有效。无效条件由共用`scene.dart`明确提示，不以坏/缺失值制造流动。

v14交付资料232条管道默认关闭箭头，但用户已明确手动开启仍不动，因此不能把默认配置当作本次用户现象的结论。没有修改v14 JSON、变量身份、绑定、启停条件或后端业务；具体现场系统设置尚未直接读取，修复针对已复现的软件阻断。

## 已有验证

- 框选、既有交互及管线专项35项passed，定向analyze无诊断。首次新增面板测试误按文本查找图标按钮，改为tooltip后完整重跑；产品断言未放宽。
- 箭头红测：保留原gate，编辑scene/客户端diagram的两项测试均失败，减少动态开启后15秒相位保持0。绿测及已有管道/跨站专项17项passed，定向analyze无诊断。覆盖持续15秒、父层重建、反向、手动关闭、条件停止、跨站、bad/stale/uncertain/unknown/离线/缺失/NaN、恢复与隐藏页暂停。
- 远端最新CI 38031925060 / f552d81为success，只覆盖其提交，不能覆盖本轮工作树。

固定Go1.24.7全量test/vet、go mod verify、Flutter3.35.4锁定依赖、只读格式检查、analyze及275项全量测试passed；安装脚本和GIS资源/巡展回归passed。Windows/Web/Go全新同源构建通过，日志及清单见[证据目录](evidence/20261030-process-edit-v15/)。源码聚合SHA256为`c39c7f950f6e4ade9755bdfc639697ed0785144f5d492ef207ca4500624cd849`。

最终完整安装EXE：`dist/installers/full-20261029-v15/Universal-HMI-20261029-Full-v15-Setup.exe`，版本0.1.0.15，225111566字节，SHA256 `4125bf17b8e153f865debc654a25f5e7244c3a9677490813a2bbe368b84e9c42`。目录/文件沿用配方日期20261029，实际本轮构建日期为20261030。内置PG18.6及5份普通资料，不交ZIP；已有v14画面无需重导。

最终EXE实际隔离v14→v15覆盖升级passed：11表摘要完全保持，5019变量、31画面及绑定/来源/导航、远程配置和维护记录保持；安装后应用文件与3059个PG文件核对通过，5204个GIS文件逐字一致。没有执行自动导入或重建。详见[升级证据](evidence/20261030-process-edit-v15/upgrade-verification.json)。

## 界面验证限制

浏览器实际交互验收blocked：测试页加载且设置prefers-reduced-motion=reduce，但仅到登录表单，提交按钮交互超时。随后Computer Use因无法可靠确定Windows浏览器当前URL、无法执行安全检查而强制中止；未绕过该检查。不能把已通过的widget测试视作本轮浏览器实际箭头/框选验收。原生GUI未启动，计unexecuted；现场MQTT及用户服务器未验。业务质量与条件门槛的结论来自自动回归，现场系统设置未读取。

隔离清理passed：mock及测试后台/PG已停止，18084/55436端口已释放；卸载后工程全文件字节不变，原四桌面快捷方式及开始菜单已恢复。见[清理证据](evidence/20261030-process-edit-v15/isolated-installer-verification.json)及[界面状态](evidence/20261030-process-edit-v15/ui-review-status.json)。18153与真实工程本轮未操作。
