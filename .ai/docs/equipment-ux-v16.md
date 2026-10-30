# 设备台账菜单、图片及用户端布局 v16

2026-10-30。产品要求以[agent.md](../../agent.md)为准，唯一活跃状态见[看板](../../AI_BOARD.md)。用户要求设备台账图标重新设计、菜单类似工艺图且可编辑、图片可选择填满并修复闪烁；补充用户端视觉优化、1920×1080实际检查、测试后重出完整安装包且不覆盖配置。用户截图还显示同一设备列表“未知”而详情“停止”。

## 实现与审查

后端equipment维护独立导航配置和可选photo_fit，原始设备归属、变量、工艺导航及图片字节不由升级改写。具体接口和边界遵循[架构](architecture.md#设备台账导航与图片显示2026-10-30)。Sol负责后端，Terra负责台账前端，root负责图标、集成审查和实际界面验收，Sol执行发行。

台账顶部图标使用原创矢量“档案+齿轮”，适配普通页面的灰蓝/彩色选中和GIS深色导航；其他图标及外壳不改。开发端设备目录支持分组、改名、改目标、上下移动及移除，运行端只读搜索折叠。默认目录在客户端隐藏无设备站区，仍可从“全部设备”查看已授权设备；开发端保留完整站区供维护。菜单加载失败显示提示和重试，不伪装已保存配置。

图片请求和base64解码由build移至按API/设备/图片身份维护的Future，使用稳定字节缓存；请求变化时新的FutureBuilder清掉旧画面，失败允许重试。完整显示、等比裁切填满、拉伸填满均可选，运行端临时选择不写工程，开发端可保存默认值。旧无photo_fit设备保持完整显示。

宽屏档案面板为视口28%、限制420–520px，图片比例1.65，客户端隐藏上传限制与机器文件名。目录使用共享32px搜索与石墨选中，列表底色更接近阅读区。窄屏继续使用滚动档案弹窗。列表/详情revision不同是截图状态分歧的一条已复现路径：打开和刷新详情后同步两处档案快照，再订阅状态；保留后端revision、质量和新鲜度校验。

## 验收清单及当前证据

- passed：固定Go1.24.7设备/服务器包及新HTTP与领域专项，权限、revision冲突、非法节点、已删站过滤、图片模式、照片及信号回归；见[evidence](evidence/20261030-equipment-navigation/backend-regression.json)。
- passed：Flutter3.35.4设备专项11项和定向analyze无诊断，涵盖目录改名保存/搜索折叠、图片模式与API切换、列表详情修订同步、迟到状态/离线、只读与窄屏、表单冲突。root增加同图片8轮2秒重建ImageProvider相等检查后11项再次通过（本项为工具输出摘要，未伪造原始日志）。图标及header定向dart analyze无诊断。
- passed：全量Go test/vet、go mod verify、Flutter analyze/279项测试、只读格式、字体、维护脚本、打包与GIS资源/巡展回归；fresh Go、Windows/Web同源构建，源码摘要`6e880a04a08166c8e36af7f8145e23194e2305d0f645698e09d7ed32f5aef06b`。见[构建记录](evidence/20261030-equipment-v16/build-result.json)及同目录原始日志。本地证据不冒充远端历史CI覆盖本批工作树。
- passed：root通过Chrome DevTools实际检查1920×1080多设备/单设备列表、原创图标、档案比例和长参数换行；三种图片模式可见。14:57:35至14:58:09持续展示并切换模式，同图请求始终1次，静态截图无重新加载占位；这不等于长期逐帧性能测量。开发端菜单改名“循环泵设备”、上移、保存、重开一致；运行页重新进入后读取相同树，折叠和搜索“循环”正常，目标只显示1台设备，无维护入口。850×600可打开和关闭档案弹窗。两端控制台无warn/error。见[完整显示截图](evidence/20261030-equipment-navigation/runtime-1920-contain.png)、[自定义菜单截图](evidence/20261030-equipment-navigation/runtime-1920-custom-menu.jpg)与[实际检查记录](evidence/20261030-equipment-navigation/browser-review.json)。
- passed：最终完整EXE隔离v15→v16升级，11表摘要、5019变量、31画面及绑定/来源/工艺导航保持；旧设备原始JSON（无photo_fit、缺signals兼容样例）与PNG/JPEG字节保持；升级不会自动创建equipment_navigation。PG3059文件、GIS5204文件及5份普通资料核验。见[升级证据](evidence/20261030-equipment-v16/upgrade-verification.json)。升级保留核对完成后才在隔离工程新增UI演示设备和菜单，未将这些演示数据放入交付包。
- unexecuted：本轮真实浏览器网络故障恢复、窄窗完整滚动/多屏DPI、原生GUI和现场MQTT。图片切换、迟到状态、修订同步及失败行为分别按专项自动回归计证，不将其写作现场实测。
- passed：mock推送已停止，隔离后台与PG停止，18084/55436重新绑定确认空闲；卸载后工程全部文件字节保持，四个桌面/开始菜单原快捷方式恢复。见[清理证据](evidence/20261030-equipment-v16/isolated-installer-verification.json)。18153未被本轮操作；清理时只读检查未见该端口监听，不据此声称当前服务在运行。

实际界面检查必须独立于widget测试记录。v15的Computer Use浏览器URL识别阻断是上一轮限制，不算本轮截图证据；本轮使用具备URL上下文的专用浏览器工具。18153和现场工程本轮不操作。

## 完整安装包

[Universal-HMI-20261029-Full-v16-Setup.exe](../../dist/installers/full-20261029-v16/Universal-HMI-20261029-Full-v16-Setup.exe)，版本0.1.0.16，225149836字节（约214.72MiB），SHA256 `f52bf7aaa2ffd752c79c316546280b2aaf44f9cfaf52a402a7c902a0607c8b39`。文件名日期沿用既有配方，本次构建为2026-10-30；不提供ZIP。安装升级为preserve-only，不调用工程重建、导入或重置。已有设备、图片、信号绑定、变量、来源与历史继续使用；旧设备未指定图片模式时仍完整显示。内置PostgreSQL18.6，WebView2仍是既有外部前置依赖。见[发行核验](evidence/20261030-equipment-v16/release-verification.json)。
