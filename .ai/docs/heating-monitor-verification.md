# 2026-10-26 供热工艺监视页验证

范围：按用户参考图改善工艺监视页；使用现有开发页、schema v1、设备素材和管道编辑工具。未收到点位表，本轮不推定真实测点。GIS由独立工作项负责，本页的GIS入口保持待接入状态。此记录是当前工作树的本地证据，不是远端CI或现场验收。

## 实现

- `app/lib/features/process/monitor.dart` 组织深蓝只读外壳、实际工程站点列表、搜索/切站、已保存画面读取和错误重试；使用宿主的真实点位快照。
- `app/assets/process/templates/heating-monitor.json` 是1574×674、94个独立元素的可编辑模板，其中27个数值元素全部未绑定。数据占位为破折号加单位，箭头仅为静态设计流向。
- 新模板位于开发页→新建模板→集中监控换热站（深蓝参考图），由 `ci/build_heating_monitor_template.py` 复现。
- 用户指出的换热器接管缺口用原图管孔坐标及模板层次修正；管线在法兰图层上方进入管孔。电子温度表、紧凑压力变送器、弹簧式泄压阀、不锈钢拼装水箱分别作为独立素材。
- 474项素材包括458项既有FUXA SVG、6项原创SVG和10项生成PNG。PNG原始alpha字节保留，绘制/素材库/拖放预览共用 `ProcessSymbolArtwork`。

## 已通过

| 检查 | 结果 |
| --- | --- |
| Go `go test ./...`、`go vet ./...` | 本轮前段全部通过；本任务未修改Go，工作树同时含既有KP修改 |
| Flutter analyze | 无问题，见[日志](evidence/20261026-heating-monitor/analyze.log) |
| Flutter全部测试 | 144项通过，见[日志](evidence/20261026-heating-monitor/flutter-test.log) |
| Python素材完整性 | 3项通过，474项几何、SVG/PNG格式及生成结果一致；`process_symbol_geometry.py --check`通过 |
| Web release | 独立绝对输出目录构建通过，见[日志](evidence/20261026-heating-monitor/web-build.log) |
| Windows release | 构建与产物验证通过，源码摘要 `3b23eee9bd349d1abdb28f5719ec10688564b8a6cf602173a91a1f938d92c0e1`，见[日志](evidence/20261026-heating-monitor/windows-build.log) |
| 实际Chrome | 独立profile加载，站点搜索/01→02→03→01切换，新建模板、保存revision1、切回只读页和刷新重开通过；控制台Errors0/Warnings0 |
| 窄尺寸 | 1180×720和600×600无溢出；缩小时显示文字偏小提示，可放大或使用变量表。600宽不是完整图数字可读性的保证 |

新增回归覆盖模板序列化、端口移动/缩放/旋转、层次、PNG透明及尺寸、动态站点列表、只读无写入、旧站迟到请求、读取失败和重试。实际浏览器保存得到[94元素文档](evidence/20261026-heating-monitor/saved-screen.json)，revision1、绑定数0。

## 图片与素材来源

### 顶部与侧栏外观补充（2026-10-26）

`monitor_chrome.dart` 将导航与站点菜单作为展示组件独立出来。六张透明图标通过内置image_gen生成，原始字节和[完整提示词](../../app/assets/monitor/prompts.json)保留在[导航素材目录](../../app/assets/monitor/README.md)。每功能一张PNG；代码实现未选中的柔和亮度、选中的青蓝辉光/玻璃底/底线，以及悬停180ms渐变。侧栏选中项使用发光边线、渐变底和同风格站点图标。星点背景为静态绘制，减少动画设置关闭状态过渡。

实际Chrome已检查1800×1000、1180×720、600×600，站点切换/搜索/清除与悬停正常，控制台Errors0/Warnings0。此处只记录工艺页外观验证；共享目录中并行进行的GIS入口接入由对应工作项负责。

最终共享工作树Flutter analyze无问题、145项测试通过、Web release与Windows release通过；Windows源码摘要`9d51c7941905067a14232064c25cbf436ebc296cbe817cccee023d739ad5f7a8`。一次Windows编译期间共享源码变化触发完整性检查拒绝，重跑后通过，未忽略该检查。日志：[analyze](evidence/20261026-heating-monitor/monitor-chrome-analyze.log)、[测试](evidence/20261026-heating-monitor/monitor-chrome-test.log)、[Web](evidence/20261026-heating-monitor/monitor-chrome-web.log)、[Windows](evidence/20261026-heating-monitor/monitor-chrome-windows.log)。

外观证据：[最终宽屏](evidence/20261026-heating-monitor/chrome-wide-final.png)、[1180宽切站高亮](evidence/20261026-heating-monitor/chrome-1180.png)、[600宽搜索](evidence/20261026-heating-monitor/chrome-narrow.png)、[悬停](evidence/20261026-heating-monitor/chrome-hover.png)。内置浏览器改用同一隔离服务的`http://localhost:18151/?view=process`，已确认显示新图标；避免原127.0.0.1来源的旧资源缓存。

用户反馈顶部挤压工艺区后，桌面导航由112px降至76px，窄屏由164px降至112px，图标由74px降至48px；保留文字、选中辉光与悬停状态。桌面释放36px、窄屏释放52px给主体。

压缩版Flutter analyze、145项测试、Web/Windows release通过（源码`b1f81523017ba6f057859e0128d447d4127a36b8620799025a7f1a80802f3052`）。首次测试发现时钟在测试字体下换行导致溢出，改为单行等比适配后通过，未放宽断言。[1180宽](evidence/20261026-heating-monitor/compact-1180.png)、[600宽](evidence/20261026-heating-monitor/compact-600.png)及内置浏览器已检查；日志保存为同目录`monitor-compact-*.log`。

[无保存画面的明确参考态](evidence/20261026-heating-monitor/reference.png) · [保存并刷新重开](evidence/20261026-heating-monitor/saved-reopened.png) · [1180宽](evidence/20261026-heating-monitor/1180.png) · [600宽](evidence/20261026-heating-monitor/600.png)。

素材使用内置image_gen生成，保存于[工程素材目录](../../app/assets/process/examples)。[首版提示词](../../app/assets/process/examples/heat-exchanger-v1-provenance.txt)、[第二组提示词](../../app/assets/process/examples/equipment-v2-prompts.json)、[最新四素材提示词](../../app/assets/process/examples/equipment-v3-prompts.json)已保留。生成图不是厂家认证机械图。

## 边界与复现

独立预览 `http://127.0.0.1:18151/?view=process`，资源和数据在 `.local/heating-monitor-preview/`。三个“示例站”各有一个明确的布局占位点，用于提供现有站点目录；没有接入来源、没有注入样本、未绑定画面。站01保存的文档仅属这个隔离环境。

未修改或重启用户18139、KP11005及GIS18149。未推送本批代码，原基点f552d81的CI38031925059和38031925060成功不覆盖本批。真实站名/点位绑定、GIS正式接入、Windows人工DPI/现场设备及用户视觉验收尚未完成。用户最终意见优先于本地截图判断。

Web构建需用绝对路径：`flutter build web --release --no-pub --no-web-resources-cdn --output=D:/DEV_D/KPimport/.local/heating-monitor-preview/web`，不要覆盖正在服务18139的 `app/build/web`。Windows命令为 `python ci/build_release.py windows`，没有 `--target` 参数；一次误用参数被拒绝后已用正确命令完成。Chrome旧profile曾缓存旧程序，最终证据使用全新隔离profile。
