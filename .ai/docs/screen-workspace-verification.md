# SSE 与画面工作空间验证（2026-10-26）

范围：最左侧公共活动栏、用户/开发模式、公共/站点 GIS 与工艺图目录、手动添加 GIS、后端内存值经 SSE 刷新，以及下方追加的客户布局与GIS编辑。既有工艺图、图层及绑定质量语义保持。先使用隔离预览18152，最新GIS编辑后端使用独立18153与测试临时目录；未连接生产 MQTT、未操作设备、未改18139/11005。

## 代码合同

- Go：`backend/internal/runtime/engine.go` 的 SnapshotJSON 在锁内冻结序列化；`backend/internal/server/runtime_stream.go` 有界 SSE 与写截止；auth/KP 中间件提供会话复核。runtime/events 只有读取语义，不增加控制入口。
- 画面：`backend/internal/process/screens.go` 统一 kind/作用域/revision；缺省 kind 兼容 process，GIS 禁止工艺节点，跨类型/站点原地覆盖冲突。跨范围目录只返回元数据。
- Flutter：`shared/api.dart` 与 `shared/sse.dart` 负责鉴权、帧解析、会话终止；main 共享订阅，画面仍按稳定 point_id 读取内存镜像。screen_explorer 活动栏仅切换侧面板及资源树，main 保留原开发端，monitor 承载独立客户展示页。工艺草稿独立，用户模式不暴露新增入口。

## 本批结果

- passed：Go `go test ./...`、`go vet ./...`；GIS 跨范围保存重启、SSE 初始/更新/撤销/重连覆盖。
- passed：Flutter analyze、完整149项测试；最终标题/深色输入框样式修正后追加18项工艺/资源树回归。面板依次切换时中央编辑器 Element 保持同一实例，站点与两张画面选择独立。
- passed：Web、Windows release，最终源码指纹 `f1b9d387f825175a988fe392cc9ef8568b3827c0542656ccf60ee062b7cc9e36`。构建日志在 [证据目录](evidence/20261026-screen-workspace/sidebar-web.log)。
- passed：实际 Chrome 1367×850 运行工艺页无开发活动栏、工作台或新增入口，站点→画面叶子加载已保存文档；深色搜索框可读。截图 [运行态](evidence/20261026-screen-workspace/runtime-process.png)。
- passed：开发端点击活动栏仅替换相邻侧面板，中央总览保留；从面板手动添加公共 GIS 后才打开中央地图。[开发端添加 GIS](evidence/20261026-screen-workspace/developer-gis.png)（截图早于最终标题文字修正）。
- passed：浏览器网络确认单条 `/api/v1/runtime/events` 200 连接，运行快照 HTTP 仅初始化2次；直接读取流得到0.0/0.5/1.0秒三帧。未连接现场 MQTT。
- passed：GIS 离开重进两轮均 playing=true、进度约0.008；清洁浏览器核对嵌入页6.032秒完成，站标 `.is-movable` 数量为0。后续追加改为仅开发编辑器允许拖动，独立展示和客户展示均只读。
- passed：内置预览切换到 `http://localhost:18152/?view=process`；开发端独立入口为 `/`，首页 GIS 为 `/?view=gis`。本次启动新隔离进程，未替换既有18151进程，只复制示例点表与画面JSON，历史SQLite由新目录创建。
- unexecuted：Windows窗口人工交互、原生 GIS、现场 MQTT/KP、真实点表/站址与容量验收。

## 明确边界

SSE 是约500ms合并的最新状态流，不是每一条 MQTT 消息的历史保证；断线补当前快照，历史持久化仍归独立存储。32连接/慢写5秒限制已实现，15,000点与多客户端长期负载未重新验收。GIS实例目前复用同源资源包，示意站址和未知数值不冒充实际站点/点表；原生GIS仍提示浏览器，未新增原生WebView。基点 f552d81 的既有 CI 为成功，但不覆盖本批未提交改动。

## 客户布局与GIS编辑追加（2026-10-26）

- passed：Go全量test/vet；GIS配置保存重开、画面隔离、陈旧revision冲突、非法坐标及重复ID拒绝。
- passed：Flutter完整150项；最终纯画布提示清理及只读配置回调修正后12项回归，analyze无问题。覆盖非法坐标、新增草稿、位置回传、预览禁写、保存失败保留与成功重开。
- passed：最终Web release 83.5秒、Windows release 34.9秒，源码SHA256 `52abb24935699f5261b8f6c137a6d32ea1ee8644d36d63b79a04c4eeab8b8065`。构建保留既有字体图标家族提示，未阻断构建；不冒充原生GIS验收。
- passed：1367×850实际Chrome中GIS边界为 `(0,76,1367,774)`，6站、0个可拖动标记，credits与source-info均display:none。工艺页为218px站区导航和纯画布，没有参考说明、工具栏和底部状态条；[工艺截图](evidence/20261026-runtime-clean/runtime-process.png)、[GIS截图](evidence/20261026-runtime-clean/runtime-gis.png)。最终浏览器控制台0错误、0警告。
- passed：开发活动栏切换只替换侧面板；打开公共GIS资源后才显示编辑器。拖动中心站并新增临时验证站，保存后HTTP重读确认7站及新坐标；预览0可拖动标记、无新增入口且URL保持开发端。随后在编辑器移除临时站并恢复原坐标，再保存重读revision=3、原6站。客户重新加载只读保存结果。
- passed：开发端“画面预览”打开独立只读对话框，不进入客户端。编辑器和预览分别6/0可拖动标记。用户内置预览已更新 `http://localhost:18153/?view=process`；开发入口为根路径。
- 隔离服务18153使用新GIS后端与独立数据目录，仅复制示例点表/画面JSON，SQLite重新创建。旧18151/18152未停止或替换。
- unexecuted：Windows窗口人工/DPI、原生GIS、真实站址/点表、现场MQTT/KP及容量验收；来源许可仍在随包THIRD_PARTY_NOTICES.txt中。

日志位于 [本批证据目录](evidence/20261026-runtime-clean/web.log)，完整测试和最终回归分别保留。

## GIS重播与透明导航追加（2026-10-26）

- passed：Flutter analyze、监视/GIS编辑6项回归，Web release 83.4秒、Windows release 35.2秒；最终源码SHA256 `cb3e58523b2df24ec37a2e4cffbc2c49aca3c1ffc747a42a40bb2f71640f2fc3`。本轮无Go改动，沿用上一批Go全测/vet结果。
- passed：1367×850 Chrome地图bounds=(0,0,1367,850)，导航透明覆盖；全屏按钮/海面开关数量均0，海面enabled/visible/animated均true，右下角纯图标重播。工艺菜单点击成功卸载iframe并显示站区搜索，切回GIS重新入场；widget验证工艺导航背景恢复。
- passed：实际鼠标平移后镜头经纬度为122.98341376008962/39.70773164207852，高18509.791283612503m。点击重播的首帧三值完全不变，随后平滑拉远再完成6秒飞入，归位122.967/39.681、高18500m。拉远途中再次点击仍从当时位置开始，无24,000,000m瞬时跳变；最终6站显示、海面继续运动、控制台0错误/警告。
- passed：JS语法检查。重播只修改相机，不改文档、站点草稿或后台配置；来源许可保留。原生GIS与现场验收仍未执行。

[最终截图](evidence/20261026-gis-replay/runtime-gis.png)；[analyze](evidence/20261026-gis-replay/gis-replay-analyze.log)、[回归](evidence/20261026-gis-replay/gis-replay-tests.log)、[Web](evidence/20261026-gis-replay/gis-replay-web.log)、[Windows](evidence/20261026-gis-replay/gis-replay-windows.log)。


## 编辑态多画面页签追加（2026-10-26）

- passed：Flutter完整153项测试。旧站点选择测试按现有资源树与独立文档页签流程更新，仍检查四张画面的范围、数值绑定和活动栏不替换编辑器；未删减失败断言来绕过功能。
- passed：最终控制器移交时只清理自身属性提交回调后，15项工艺/GIS/多页签回归；analyze无问题。新增覆盖同站独立草稿、输入尚未失焦即切页、撤销记录保留、重复打开去重、关闭取消/放弃/相邻选择、异步读取不抢回焦点，以及GIS保存期间切页仍更新原草稿revision。
- passed：Web release 83.7秒、Windows release 10.4秒；源码SHA256 `1ddf406ae63e31b1093759bb27e07bfc0a016b034b1adb15abf1f9367b9988a9`。本轮仅Flutter及文档改动，Go沿用前批结果，未重新声称后端测试。
- passed：实际Chrome1367×850打开工艺图→改名未保存→GIS→点击工艺页签，名称和未保存标识保留，点击撤销恢复原名称。新建同站空白模板成为第三张独立页签，切回原图仍保留GIS和新模板；[最终截图](evidence/20261026-editor-tabs/editor-tabs.png)。Flutter语义代理输入框不暴露实际value，名称以画面页签/属性区可见渲染核验。
- passed：最终控制台0错误/0警告；HTTP复读原工艺图仍为名称“换热站工艺流程”/revision1，GIS仍revision3，两张已保存示例图未修改。新模板仅测试浏览器内存草稿，测试浏览器关闭；内置预览更新到 `http://127.0.0.1:18153/`，保留原工艺/GIS两页签供继续编辑。
- unexecuted：Windows人工窗口交互与原生GIS，刷新/退出后的未保存草稿恢复不在本批实现；没有新远端CI，旧CI不覆盖工作树。

[analyze](evidence/20261026-editor-tabs/analyze.log)、[完整测试](evidence/20261026-editor-tabs/tests.log)、[最终回归](evidence/20261026-editor-tabs/final-tests.log)、[Web](evidence/20261026-editor-tabs/web.log)、[Windows](evidence/20261026-editor-tabs/windows.log)。


## 2026-10-26 GIS浮窗变量绑定

用户先反馈图标拖动与绑定入口，随后确认图标已可拖动；本批保留原图标拖动和悬浮行为，补齐浮窗绑定，不把未复现问题冒称已修复。

- passed：Go全量test/vet及Windows后端构建；GIS坐标移动后绑定仍保存、重新打开、revision冲突、非法指标与非法point ID拒绝。MCP使用明确GIS schema，和HTTP共用画面服务。
- passed：Flutter analyze、完整155项及11项相关测试。覆盖跨站同名变量按ID选择、搜索/取消解除/确认草稿/保存重开；地图弹窗禁用iframe指针；实时质量/非数值/离线不显示正常数值。
- passed：Web release54.1秒、Windows release37.6秒；Windows构建源码摘要4b8294f0a48e05f666e4c3b9586e856e0e6093e2168b65c62458afe6d32924ba。初次Web相对输出目录触发Windows shader写路径失败，改用绝对隔离输出目录后通过，没有修改产品源来绕过编译。
- passed：独立18154/临时数据实际Chrome从浮窗“绑定变量”选示例站02的温度（与示例站01同名），确认仅改草稿、保存v5、拖动45×20px后保存v6，HTTP读回绑定ID保持。真实手工测试值42.25→48.75、客户页读回51.50→52.50，浮窗保持打开且没有地图重建；客户页可拖图标/绑定按钮均为0。
- passed：1367×850与960×640对话框视觉检查、最后一项和确认可达。关闭自有18154测试服务后，已打开浮窗显示“— °C 离线”；CDP模拟offline未断开既有SSE，未把该轮计为断线通过。测试服务关闭产生预期连接失败日志，正常操作阶段无console error/warn。
- passed：18153已使用新后端与独立Web目录.local/gis-binding-preview/web，PID8948；原.local/gis-editor-preview/data全部已保存画面SHA256前后相同，没有为用户预设猜测绑定或注入测试数值。测试数据仅位于18154目录，该测试服务已关闭。用户页面保留未主动刷新，保存现有草稿后刷新加载新入口。
- passed：独立浏览器强制刷新18153后，从开发页公共站区地图进入站点，确认新版拖动提示和五项浮窗变量绑定入口实际可见；取消退出，未改写用户画面。
- unexecuted：真实测点/生产站址、原生GIS交互、Windows DPI和正式现场。变量反向引用、独立多工程属于既有未完成范围。

[绑定配置](evidence/20261026-gis-bindings/gis-binding-dialog.png)、[实时浮窗](evidence/20261026-gis-bindings/gis-binding-value.png)、[窄窗口](evidence/20261026-gis-bindings/gis-binding-narrow.png)及同目录测试/构建日志。基点f552d81的CI38031925059/38031925060已复核success，仅覆盖基点，不覆盖本批未提交工作树。

## 2026-10-26 GIS透明导航点击修复

- failed/reproduced：旧18153未启用Flutter语义层（flt-semantics=0），在996px紧凑布局真实点击工艺菜单144,66，地图iframe仍存在；document.elementFromPoint实际返回iframe。之前组件/语义点击不能覆盖DOM原生事件分发，此次不沿用其成功结论。
- passed：monitor.dart仅在GIS叠加导航包裹platform/pointer_shield*；Web透明div以isVisible=false嵌入，仅接收导航范围事件，Flutter负责按钮命中；原生直接返回child，无新依赖、后端或变量保存变动。
- passed：18155独立预览使用真实page.mouse点击，996×1119紧凑和1280×800宽屏四菜单分别从GIS切出并可切回。全过程semantics=0。宽屏隔离范围实测0,0,1280,76；下方命中仍是iframe，拖图后相机从122.967/39.681变化到122.974779/39.693041。
- passed：Flutter analyze无问题、全量155测试、Web release40.4秒、同工作树Windows release141.8秒，源码4534d32cd7d0ae9fd89610fe9136bd4689f1861f84e93d6bec14ce509437e2c8。初次analyze遗漏rendering枚举import已修复；后一次分析遇到同时新增的原生GIS文件lint，后续该文件更新后最终全量通过。原生GIS的同时开发不在本次鼠标隔离验收范围。
- passed：修复静态资源更新到18153，main.dart.js SHA256 A079D41ACFA2C5CAAB5D3770BE413576FB2982BABD0F7371202B4ADB8631E32B；独立浏览器强刷后确认隔离层和真实工艺菜单点击生效。已保存画面SHA前后相同，未刷新用户现有浏览器。18155测试进程已关闭。
- unexecuted：真实KP容器、原生GIS鼠标、现场设备与多DPI。仅展示层修改，无Go源码改动。基点f552d81 CI38031925059/38031925060仍success，不覆盖本次工作树。

[修复后页面](evidence/20261026-gis-navigation/gis-nav-fixed.png)、[复现页面](evidence/20261026-gis-navigation/gis-nav-map-before.png)和同目录analyze/tests/Web/Windows日志。

## 2026-10-26 GIS上方弹窗统一检查与修复

- failed/reproduced：旧18153打开“添加画面”后，取消按钮位置785,513实际命中iframe，pointer-events仍为auto，Flutter semantics为0。原有dialogOpen只覆盖站点自身编辑，无法覆盖祖先打开的确认框/菜单。
- passed：GisScreen结合所属ModalRoute顶层状态统一控制interactive。新增回归覆盖外部确认、嵌套下拉、菜单、GIS预览及预览上的确认，断言每层地图暂停/恢复正确。
- passed：Flutter analyze无问题、完整158项、GIS相关4项；Web release42.8秒、Windows release39.1秒，Windows构建源码SHA256 a52eac0213110f7fb7b5c8d53c4e9711d08af3d04bbf184e1d494069fa4a5d00。本批产品改动仅gis_screen.dart与对应测试，不含并行进行的Windows GIS适配实现。初次测试从仓库根目录执行因找不到pubspec失败，切到app后通过。
- passed：独立18155临时数据，1367×850真实Chrome、semantics始终为0。添加画面输入名称、站点下拉选项、取消；地图拖动后关闭脏页签，取消保留草稿，再次确认放弃关闭；站点配置→嵌套变量搜索03→逐层取消；项目菜单打开/Escape关闭；点击顶部工作区入口打开选择框、点击遮罩关闭；GIS只读预览打开后两iframe中仅顶层auto，点击关闭后底层恢复。未改写用户画面。
- passed：640×300站点编辑内容滚动到最后一项，取消/确认按钮可见；嵌套变量选择的搜索与取消可见，逐层取消后地图恢复。截图见下方。
- inconclusive：一次连续自动化在下拉关闭后立即Ctrl+P等待工作区弹窗超时；随后使用可见顶部入口打开和遮罩关闭通过。此轮不声明Ctrl+P快捷键通过。另一次拖动结束后立即关闭页签早于异步草稿事件处理，后续分步等待再操作复现脏页签并通过取消/放弃路径，未把首次等待超时算成功。
- passed：18153静态Web已更新，main.dart.js SHA256 E0DDFC0800AADBA0B9A8385E78111028A7886A17ED171EF73F68A10CD6BADABB。独立浏览器强制加载后重测添加画面弹窗，取消位置不再命中iframe，关闭后pointer-events恢复auto；全部已保存画面SHA256前后一致。用户浏览器未刷新，刷新前先保存当前会话草稿。隔离18155测试服务与自有浏览器已关闭。
- unexecuted：Windows原生弹窗鼠标/DPI、真实KP容器、现场设备。Go无本批源码改动，未重跑Go检查；基点CI不覆盖本次未提交工作树。

[旧版复现](evidence/20261026-popup-audit/popup-add-before.png)、[添加画面下拉](evidence/20261026-popup-audit/popup-add-dropdown.png)、[草稿确认](evidence/20261026-popup-audit/popup-close-confirm.png)、[变量搜索](evidence/20261026-popup-audit/popup-point-search.png)、[预览](evidence/20261026-popup-audit/popup-preview.png)、[小窗口滚动](evidence/20261026-popup-audit/popup-station-small-scrolled.png)、[小窗口嵌套选择](evidence/20261026-popup-audit/popup-picker-small.png)、[18153部署检查](evidence/20261026-popup-audit/popup-deployed-fixed.png)。测试及构建日志见同目录。

## 2026-10-26 页签菜单与内容归属

- passed：公共/站点工作区显示对应运行导航，跨站比较仅公共范围可用；GIS/工艺文档去除固定运行导航，直接显示自身工具栏。打开文档前保存当前工作区会话，切回或关闭最后文档恢复原功能。GIS预览标志随内存GisDraft按文档ID保留，不写入文件。
- passed：新增页签回归覆盖变量监视→GIS预览→工艺图→公共工作区→GIS，检查菜单类型、公共页选中态、GIS预览恢复与关闭回退。初轮8项相关测试通过；最终Flutter analyze无问题、完整160项通过。
- failed/reproduced then passed：实际浏览器快速点击加载中的目录，旧默认“首页 GIS”占位会先被打开，随后读取真实公共地图，造成临时空ID/名称不一致。ScreenExplorer改为读取成功且确无公共GIS时才显示默认入口；新增延迟目录测试。最终浏览器延迟目录请求1.5秒，加载中点击原占位位置没有打开地图，完成后只打开“公共站区地图”。
- passed：最终Web release36.2秒、Windows release35.5秒；Windows源码SHA256 b13857cc14d54997456f6926da6313a2405e4d7792ba4a969aaf4fd06996c357。此前159项/中间构建由最终结果替代；没有Go产品改动，未重跑Go检查。
- passed：独立18155实际Chrome1367×850，真实鼠标验证公共菜单、单站无跨站比较且仅一条站点变量、工艺编辑工具栏、GIS自身预览/保存工具、切回公共变量监视、GIS预览状态恢复。最终截图的GIS标题与实际文档一致。未启用Flutter语义代理；普通reload曾仍加载旧缓存，最终CDP禁用缓存/绕过service worker并等待load后复测，不把缓存旧页算最终通过。
- passed：18153静态Web已更新，main.dart.js SHA256 A1A36E28BF1406E6CF5ABC8809645754C5C7586A2D7BB57B661B0882720A21C5。独立浏览器实际确认GIS页显示对应工具栏，切回公共总调度恢复变量监视；已保存画面全部SHA256前后一致。用户现有浏览器未刷新，当前草稿仍需先保存后强刷。隔离18155服务与自有浏览器关闭。
- unexecuted：Windows原生菜单交互、多DPI和真实KP容器；未更新dist临时包、未产生新远端CI，旧CI不覆盖工作树。

[GIS菜单](evidence/20261026-tab-menus/tab-menus-gis-final.png)、[工艺工具](evidence/20261026-tab-menus/tab-menus-process.png)、[GIS预览恢复](evidence/20261026-tab-menus/tab-menus-preview-restored.png)、[工作区恢复](evidence/20261026-tab-menus/tab-menus-workspace-restored.png)、[单站菜单](evidence/20261026-tab-menus/tab-menus-station.png)、[目录加载检查](evidence/20261026-tab-menus/tab-menus-loading.png)、[18153读回](evidence/20261026-tab-menus/tab-menus-deployed-return.png)。analyze、完整测试及Web/Windows构建日志见同目录。
