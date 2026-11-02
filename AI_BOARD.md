# 唯一活跃工作看板

2026-11-02 SECURITY-MOBILE-v20 in_progress：真实设备mTLS、账号/审批代次会话绑定、即时撤销、Coraza/请求CRS、有界限流与持久封禁、本机审批/解封和原生Java只读Android已实现。最新追加公网Web/手机5位后端图形验证码（2分钟/单次/来源绑定）并取消强制MFA首次绑定；用户确认当前无MFA账号，不重置真实账号。Go全test/vet/mod verify、Flutter462通过/2浏览器跳过且analyze通过、Android5 JVM/签名release/lint通过。真机Keystore预哈希TLS兼容故障已修复，物理手机证书握手加载页面通过，图片登录交互继续验证。正式设备证书默认10年、可配置1..36500天、审批可跟随叶证书且可撤销。最终Windows/Web fresh重建、EXE及保留升级验收进行中；当前CI macOS因缺Go许可证工具失败，已显式加入固定Go工具链待复验。现场公网/18153与真实工程未动；用户禁止当前公网探测，真实部署验收仍未执行。

2026-10-30 GIS-ZONES-UX-v19 done：GIS站公共数据＋有序分区、工艺/公共GIS多通配绑定搜索、变量卡片名称/站点/单位完整换行完成。Go全test/vet、Flutter289项/analyze、fresh Windows/Web/Go同源4ed187f9通过；完整EXE0.1.0.19，227682820字节，SHA256 4fa559d5eed0c3a9af6dc9f896a93c1efbaa5da5690ea0fa83e045c6c595c06f。隔离v18→v19升级11表/5019点/31图、来源/绑定/设备资料图片与导航保持，PG3059/GIS5204核验。真实Chrome改名/排序/保存重开、多通配绑定、四区1920两列/600单列滚动、单区及长卡片1920/850通过；隔离卸载保工程、快捷方式恢复与18084/55436释放通过。18153/现场未动，原生完整手工与多DPI未验。保留升级无需重导，无新增活跃子任务。[产物与验收](.ai/docs/gis-zones-v19.md)。

2026-10-30 ICON-VARIABLE-UX-v18 done：同系列台账PNG、统一变量通配/多选及窄窗命令栏/资源树抽屉/工具栏换行完成。Go全test/vet、Flutter285/analyze、fresh Windows/Web/Go同源422f00f0通过；完整EXE0.1.0.18，227663754字节，SHA256 1e754ce5d022dce069362d7a35395a46a1f2da8f49b56711692cfe51b789ea0d。最终v17→v18隔离升级11表/5019点/31图/设备资料图片与菜单保持，PG3059/GIS5204核验，卸载保工程/快捷方式恢复/端口释放通过。实际Chrome850×600、884×561、1920×1080搜索批选/抽屉/曲线超限通过；Windows96DPI最小900×600与正常退出通过。自动化fill星号keyup位置错误已捕获，type_text正常，未改应用键盘逻辑；不声称零控制台错误。18153/现场未操作，手工原生全流程/多DPI未验。完整EXE已按用户要求先交付，保留升级无需重导，当前无新增活跃子任务。[产物与验收](.ai/docs/icon-variable-v18.md)。

2026-10-30 ICON-VARIABLE-UX-v17 superseded：用户要求台账图标匹配既有PNG风格，并确认扫描添加、变量列表、曲线/关注添加三个入口的通配符/多条件/多选。root生成同系列素材并统一MonitorHeader；共享前端匹配器对齐后端扫描语义，变量列表批量选择与趋势选择分离、Ctrl/Shift及筛选全选，曲线6条超限明确反馈。实现、专项/全量、Windows/Web构建及完整EXE待验；不改现场工程。v16为上一交付。

2026-10-30 EQUIPMENT-UX-v16 done：Sol后端/发行、Terra台账UI、root原创矢量图标与审查。独立可编辑设备目录、三种图片模式、稳定加载、宽屏档案布局及列表/详情修订同步完成；Go全test/vet、Flutter279全测/analyze、fresh Go/Windows/Web同源6e880a04通过。完整EXE0.1.0.16/225149836字节/SHAf52bf7aaa2ffd752c79c316546280b2aaf44f9cfaf52a402a7c902a0607c8b39，无ZIP。v15隔离升级11表/5019变量/31画面、设备原始JSON与PNG/JPEG保持，PG3059/GIS5204核验；root实际1920×1080、850×600、菜单改名排序保存重开/搜索折叠、三图片模式及单次照片请求通过。隔离卸载保工程、快捷方式恢复和端口释放通过；18153/现场未操作，原生GUI/现场及浏览器故障恢复未验。无活跃子任务，最新交付v16。[验收与安装包](.ai/docs/equipment-ux-v16.md)。

2026-10-30 PROCESS-EDIT-v15 done（界面验收受阻）：Sol/Terra实施、root审查。空白拖动框选、Shift追加、Ctrl+A、批量移动/复制/删除与单步撤销；修复系统减少动态错误停用手动开启的业务箭头，保留条件/质量和隐藏暂停。35项交互专项、17项箭头专项（含红绿）、Go全test/vet、Flutter275全测/analyze及fresh Windows/Web/Go同源c39c7f95通过。完整EXE 0.1.0.15/225111566字节/SHA4125bf17b8e153f865debc654a25f5e7244c3a9677490813a2bbe368b84e9c42；最终v14隔离升级11表/5019变量/31画面保持，PG3059/GIS5204核对通过；无ZIP，原v14普通JSON无需重导。Computer Use因无法确认Windows浏览器URL而中止，浏览器实际交互blocked，原生GUI/现场unexecuted，不冒充全验收。隔离卸载保留工程、快捷方式恢复、端口释放通过；18153/现场未改。当前无活跃子任务，最新交付v15；[验证及限制](.ai/docs/process-edit-v15.md)。

2026-10-30 CLIENT-STATION-MENU / PROCESS-COMPACT / INSTALL-FULL-v14 done：Sol/Terra实施，root审查。开发站平铺、客户14父28子菜单；28主图去右栏并保留386确定绑定/396待核位置，313唯一已有点匹配；可精确批量更新原28图。Go全测/vet、Flutter270全测/analyze及fresh Go/Windows/Web同源2a580c77通过；最终EXE隔离v13升级11表保持，5019变量/历史/来源不变，28图原ID与主图actual point_id保持，重复提交通过。root客户端父子菜单/搜索/切换及1440x900、800x520视觉通过。EXE 0.1.0.14/225113533字节/SHA e48c9607bf1d5a58655e81b4e55b307cc62d8a78207ddf33bbbee587eac2bc04，普通JSON位于outputs/process-navigation-v14-20261030，无ZIP。截止后停止追加验证，最终开发态/导入UI实看、原生GUI和现场未验；已有自动测试独立计证。隔离卸载保留项目、快捷方式恢复、端口释放，18153和现场未改。当前无新增活跃子任务，最新交付v14；[综合验收](.ai/docs/process-navigation-v14.md)。

2026-10-30 CROSS-STATION-DISPLAY / OWNERSHIP / INSTALL-FULL-v13 done：Sol/Terra实施、root审查。跨站数值/箭头遗留限制修复；新增按工艺画面分站、原子仅Station保存、备份/回退、规则存储依赖闭锁及运行旧归属禁删。v13保留升级不调用工程重建，现有变量无需重扫或重导图。Go全测/vet，Flutter266全测及最后6专项/analyze，fresh Windows/Web/Go同源e59954b5通过；PG5019升级11表保持、325点迁移回退再迁移、root浏览器42.5箭头及mock迁移/Apply通过。完整EXE dist/installers/full-20261029-v13/Universal-HMI-20261029-Full-v13-Setup.exe，225135443字节，SHA256 64e96f68b31df2e61f80654dc862afbe762441d697cdda605cbfed9f65efafe3，无ZIP。测试历史过期清理首次失败及修正证据保留。隔离卸载保留工程、端口停止、原快捷方式恢复。18153及现场未动，现场MQTT/公网及本轮原生GUI未验。当前无新增活跃子任务；最新交付以v13为准。[综合验收](.ai/docs/cross-station-ownership-v13.md)。

2026-10-29 SCANNED-NUMERIC-MATCH done：Sol生成独立数值类型适配资料，root审查确认仅56个INT匹配期望改FLOAT及预填截图来源ID，其他JSON字段不变，全部match_existing。独立5019扫描FLOAT夹具：旧资料56类型冲突，新资料0剩余，提交28图471原ID引用，已有变量定义逐字不变；错误类型/来源/路径/单位/倍率/偏移/歧义仍拒绝。定向Go测试通过；未改应用、安装器、18153或现场。实际现场匹配待用户预览，不能声称385全部匹配。资料及证据：[README](outputs/process-scanned-numeric-20261029/README.txt)。

2026-10-29 SERVER-MAINTENANCE-FAILURE / INSTALL-FULL-v12 done：现场只读报告定位v11严格ownerSID校验拒绝已提升Administrator的Administrators组owner工程，尚未进入备份清理。Sol修复受限组owner授权及早期脱敏诊断；Sol发行、Terra隔离验收、root审查。v12完整EXE dist/installers/full-20261029-v12/Universal-HMI-20261029-Full-v12-Setup.exe，0.1.0.12，225091023字节，SHA256 912bedd0f2bb72796474f3478de06e224f14fecf23cc07e70a663d6db4a7c09b。12项脚本回归、两次Inno早期失败42/日志不覆盖、最终v11→v12升级/显式重建/冷备恢复/重装/卸载保留通过；复用9c50应用，仅更新部署。源工程ACL不改，MQTT/GIS/身份/历史保留，迁移ID仍process-rebuild-v10。原快捷方式恢复，隔离端口释放，18153未改。真实提升管理员令牌/现场安装未测，ACL策略模拟与普通用户实测分别计证。当前无活跃子任务，最新交付以v12为准。[验收](.ai/docs/windows-maintenance-admin-v12.md)。

2026-10-29 SERVER-REBUILD-v10 / INSTALL-FULL-v11 done：Sol/Terra实施，root审查。完整EXE dist/installers/full-20261029-v11/Universal-HMI-20261029-Full-v11-Setup.exe，0.1.0.11，225088911字节，SHA256 2cc1a11563570924368d3354da91d0f68edbb2074db6c44b5cbe54ddf0ea3426。谨慎删站、原子批量删变量、MQTT扫描后match_existing完成；重建先完整冷备，保留MQTT/GIS/身份/历史，固定process-rebuild-v10标记避免重清。Go全测/vet、Flutter263项/analyze、Windows/Web构建、最终EXE隔离v9→v11升级/重建/实际恢复/重装/卸载保留通过；root实际Web删除交互通过。v10退回后v11修复部署，复用本轮9c50应用。未改18153或现场服务器，现场MQTT及本轮原生GUI未验。原快捷方式恢复、隔离端口释放，无活跃子任务。最新交付以v11为准，旧ZIP仅历史记录。[验收](.ai/docs/server-rebuild-v10-verification.md)。

2026-10-29 PROCESS-MATCH-FIX 已并入SERVER-REBUILD-v10：服务器v9真实反馈全部 candidates=0，623已有变量来自KingIO扫描。已定位UI勾选变量定义清空retry预填目标、旧auto不匹配空topic两项原因。Terra已修UI恢复/切换/批量匹配，Sol已实现显式match_existing及623合成点回归；最终发行和隔离重建已随v11验收通过，现场由用户安装。现场数据未取得，不能宣称实际623全匹配。

2026-10-29 INSTALL-FULL-v9 done：按用户要求仅交付最新完整安装EXE及普通资料，不交付压缩包。Sol复用ClientHistory应用封装PG18.6/0.1.0.9，215991875字节，SHA256 8362ff33c39bd2d5fd82449749fa8a0ea495684b906f30a73e013b59beb1bf06。Terra实际隔离v8→v9覆盖、旧账号登录、PG11表摘要、6297应用/3059PG文件、Web/GIS字节、卸载保留全部通过；6文件资料含28图/385变量，安装后普通文件可用。root复核配方/校验和/验收；四原快捷方式已恢复，18153 PID3908和工程配置保持。原生GUI本轮未重验，WebView2前置依赖保持。当前无新增活跃子任务。[发行与验收](.ai/docs/windows-full-release-20261029-v9.md)。

2026-10-29 CLIENT-HISTORY done：客户端仅GIS/工艺画面/设备台账/历史，历史只用外部数据；内部工具留开发端。Terra实施，Sol审查后端/发行，root审查修正工程师客户端额外读取来源管理的问题。Flutter完整253项及最终专项11项/analyze、Windows/Web同源构建、真实隔离SQL与Chrome日报/趋势分页/窄屏四入口/外库停机错误/开发入口通过；客户端请求无内部历史/任务/存储及来源管理。固定18153 PID3908和四快捷方式升级ClientHistory，备份20261029-172730-client-history，PG11表与GIS5204文件逐字保持。桌面ZIP已出，v8安装EXE保持；原窗口未关/页面未刷新，现场和原生GUI本批未重验。当前无新增活跃子任务。[验证](.ai/docs/client-history-verification.md)。

2026-10-29 PROCESS-BINDING 绑定包完成，现场导入待真实来源：用户指出已有变量名/KingIO对照表，重新审查纠正旧server01路径/已有pointID前提。6.1 Sol生成outputs/process-kingio-bound-20261029及ZIP：28图、385唯一KIO变量（329 FLOAT/56 INT）、471 set、441 keep；按12原始KIO分组默认归档、60共享点跨站引用同一ID，KIO全名作source_path/topic空。生产Decode、385 Normalize、隔离实际Preview/Commit/Repeat通过，逐项核验471引用，重复无新增/版本变化；主代理独立核对路径/类型/归档/图元/标签通过。import-request.json预填新建及站点映射，现场选择真实KingIO来源后可导入；已有HMI变量冲突应明确引用。原348预填包已被此完整包取代。本机18153真实工程和v8发行未改，现场连接未验，不再要求用户重复提供现有KIO表。当前无代理运行，待现场来源配置/导入。

2026-10-29 PROCESS-STATION-BUILD done：6.1 Sol/Terra实施，主代理审查、修正退回及最终验收完成。交付28张空绑定图、匿名双泵模板、JSON独立/完整包、Excel三表与CSV；276个候选和912个待绑位置保留现场确认，支持显式映射、差异预览、keep/set/clear、revision冲突、幂等和剩余清单重试。Go全测/vet、Flutter249项及末轮14项/analyze、真实HTTP/Chrome、全新Windows/Web构建通过。v8完整安装包0.1.0.8含PG18.6，隔离v7→v8覆盖、6339应用/3059PG文件、旧账号和11表、卸载保留通过。18153及四快捷方式升级ProcessTransfer，备份20261029-162619-process-transfer，真实PG11表及GIS5204文件保持；未向真实工程导入候选或测试图，原窗口保持。原生GUI本批未重验，现场KIO及公网NAT仍待现场核对。当前无新增活跃子任务。[功能验收](.ai/docs/process-transfer-verification.md) / [v8发行](.ai/docs/windows-full-release-20261029-v8.md)。

2026-10-29 INSTALL-FULL-v7 done：6.1 Sol封装、主代理审查与实际v6→v7覆盖验收通过。完整包0.1.0.7内置PG18.6，215852816字节，SHA256 7623809b…；复用已验PublicRemote应用，安装来源单独计证。6289应用/3059PG文件、十一表不变、旧账号登录、实际Web/GIS字节与卸载保留数据通过，原快捷方式已恢复。真实18153和用户工程未改，公网默认关闭。当前无新增活跃子任务。[验收与产物](.ai/docs/windows-full-release-20261029-v7.md)。

2026-10-29 PUBLIC-REMOTE done：可配置自签HTTPS、公网与本机同工程双监听、客户端远程连接/公开证书固定信任、GIS受限代理及独立远程双入口完成。6.1 Sol/Terra实施，主代理审查并修复TLS拒绝断连、执行最终实包验收。Go全测/vet、Flutter242项/analyze及最终4项回归、Windows/Web同源构建封装、真实TLS业务/SSE/拒绝/退出、桌面生命周期和4次正常退出0通过。18153及本机双入口升级dist/Universal-HMI-PublicRemote-20261029，源码e2a8499a…；备份20261029-134620-public-remote，PG十一表摘要和5204个GIS文件保持。IP留空、公网默认关闭；新增远程开发/运行入口。真实公网/NAT、远端GIS完整渲染、长期连接及可选SCM现场安装仍待验；未制作新安装EXE、未关闭原窗口或刷新页面。[配置](.ai/docs/public-remote-guide.md) / [验证](.ai/docs/public-remote-verification.md)。当前无新增活跃子任务。


2026-10-29 APP-ICON done：6.1 Sol生成及接入原创应用图标，主代理母版/32/128px审查通过。Windows程序/窗口/托盘、双快捷方式及Web图标已在本机更新，macOS/Linux资源同步。analyze、Windows/Web构建、EXE七档图标资源核对、18153七HTTP响应及5208保护文件hash通过。本轮仅图标覆盖，不是新安装EXE，未关闭旧窗口或重启后台；未重跑业务全测/Go。当前无新增活跃子任务。[验证](.ai/docs/app-icon-verification.md)。

2026-10-29 DESKTOP-LIFECYCLE done：Windows同工程开发/用户端各自单实例、重复启动唤回、关闭到托盘/最小化到任务栏及工艺/GIS退出草稿保护完成。两项行为均获用户确认。6.1 Sol/Terra实施，主代理审查并退回修复原生析构重入异常后重验。Go全测/vet、Flutter235项/analyze、最终C++修正后11项回归、Windows/Web同源封装通过；原生并发/跨端/跨工程/隐藏恢复/崩溃恢复、4次正常退出0及真实取消/保存退出0通过。固定18153及双入口配置升级dist/Universal-HMI-DesktopLifecycle-20261029，源码51e704ba…；备份20261029-120525-desktop-lifecycle，PG十一表完全不变（1账号/4站点/3文档/24审计），5204个GIS文件保留。原窗口未关闭或刷新。正式双端共享后台；裸EXE不与正式入口混用。物理托盘鼠标/Explorer重启/完整DPI/现场未验，未制作新安装EXE。[验证](.ai/docs/desktop-lifecycle-verification.md)。当前无新增活跃子任务；远端f552d81历史CI不覆盖本批工作树。

2026-10-29 PROCESS-VARIANTS done：四种匿名可编辑供热模板、目录/编辑器独立复制快建，以及编辑/预览共用纯色、渐变、上传图片和透明度背景完成。6.1 Terra/Sol实施，主代理审查并退回修正重叠、资源清理及Web图片解码问题。Go全测/vet、Flutter229项/analyze、Windows/Web同源封装和隔离Chrome复制/上传/像素对比/小窗口通过。固定18153及共享桌面入口升级dist/Universal-HMI-ProcessVariants-20261029，源码a787f6a5…；备份20261029-112036-process-variants，PG十一表内容不变，原1账号/4站点/3文档/20审计与5204个GIS文件保留，原页面未刷新。未制作新安装EXE，原生DPI/现场未验；Chrome平台单测加载挂起不计通过。[验证记录](.ai/docs/process-variants-verification.md)。

2026-10-28 INSTALL-FULL-v6完成：按用户旧界面反馈，从当前全部源码重新编译Go与全新Windows/Web输出，交付dist/installers/full-20261028-v6/Universal-HMI-20261028-Full-v6-Setup.exe（0.1.0.6，206936947字节，SHA256 7f289fe4…，内置PG18.6）。来源9ed9f77f…/905文件，Go全测/vet、Flutter215项/analyze、Windows/Web与GIS门禁通过；实际v5→v6覆盖、6270应用/3059PG文件、双入口新路径、十一表不变、旧账号登录与实际Web/GIS字节通过。隔离卸载保留工程并恢复原快捷方式；18153与真实工程未改。目标机旧界面根因尚未复现，原生DPI/现场未验。[证据](.ai/docs/windows-full-rebuild-20261028-v6.md)。

2026-10-28 INSTALL-UPDATE完成：0.1.0.5覆盖安装包dist/installers/update-20261028/Universal-HMI-20261028-PG-Setup.exe（207051797字节，SHA256 19f78600…），内置PG18.6，沿用旧安装身份及工程路径。复用ProcessSurface-v2同源应用，GIS清单通过；0.1.0.4→0.1.0.5隔离安装、6271应用/3059PG文件核验、11表摘要保持、原测试账号登录、Web/GIS字节及卸载保留数据通过，原快捷方式已恢复。仅部署版本/说明变动，无Go/Flutter重编译；固定18153和真实工程未改。原生DPI/现场未验。[证据](.ai/docs/windows-update-20261028.md)。

2026-10-28 GIS-MOON done：修复实际Edge OIT月球不显示，用户已确认可见；降低过亮月面并恢复侧光阴影，完整Chrome运行页确认。仅亚洲慢转、其余加速（7.556秒），每次落地重新站标生长；JS/5项资源测试和四轮24次入场通过。18153及桌面共享MoonRender版本更新，GIS摘要18aa7d36…，10表与原审计不变、新增1次成功登录。最终Edge光照截图因浏览器加载检查暂停未完成；不替代原生/现场验收。未重编译Go/Flutter或制作新安装EXE。普通UI仍由下方PROCESS-SURFACE跟踪。[证据](.ai/docs/gis-tour-verification.md#月球可见性光照与亚洲慢转修正)。

2026-10-28 PROCESS-SURFACE done：工艺运行区钢灰层次背景、石墨目录、顶部原彩色选中图标/无底块/下划线；追加工艺、站点范围、台账、外数据紧凑PC侧栏，切图与普通页返回保留目录树和搜索。Go全测/vet、Flutter215项/analyze、Windows/Web同源封装及独立Chrome逐页/12次切图/聚焦键入返回/850×600通过。18153 PID71016及桌面双入口升级ProcessSurface-v2，来源f71bf432…；备份20261028-171155-process-surface，PG11表摘要全相同、原1账号/4站点/3文档/12审计保留。GIS本任务未改，逐字复用已部署MoonRender的5204文件，原用户页未刷新。未制作新安装EXE、原生DPI/现场未验。[证据](.ai/docs/process-surface-verification.md)。

2026-10-28 RUNTIME-LIGHT done：普通运行页统一浅灰桌面层次，原MonitorHeader图标造型、完整标题、时钟和布局保留，普通页灰蓝配色/去光晕，GIS仍为透明原色。设计规范为 .ai/docs/design.md；台账紧凑表格与内置工艺只读配色已完成。Go全测/vet、Flutter212项/analyze、Windows/Web同源构建封装、Chrome逐页/850×600检查通过。固定18153 PID72440与桌面入口更新RuntimeLight版本，源码bd3ba71c…；原10表摘要及7条审计记录不变，审计新增2条成功登录。最新GIS资源逐字保持。原用户页未刷新，新安装EXE和原生DPI/现场未验。[验证记录](.ai/docs/runtime-light-verification.md)。

2026-10-28 GIS-INTRO done：最终为圆环演示/地图静态展示两个图标，演示立即结束浮窗并拉远，静态只轮播地面浮窗；3.5秒停留/1.4秒返回/约9.494秒变速环游，盈凸月正面远轨道、卫星延长反光、同向不同位置流星与近地缩小完成。JS/5项stage测试及Chrome六轮静态/即时切换/窄窗/减少动态/编辑态通过。固定18153 PID62408和桌面双入口已更新独立GISTour版本，只替换原已部署版本web/gis的15文件，PG十一表摘要保持。共享构建目录并行改写被组合校验拒绝，未使用其混合产物。原生/现场及新安装EXE未验/未制作；普通页面工作归RUNTIME-LIGHT，原用户页未刷新。[验证记录](.ai/docs/gis-tour-verification.md)。

2026-10-28 PERF-5000-IMPLEMENT done：授权选择/增量SSE、锁外有界批量周期历史、KingIO主动补全及逐点新鲜度、Flutter按画面订阅已实现；逐页检查并统一工艺目录/标题蓝灰色。5000点/50独立账号各100点短测50/50成功，全变SSE合计9.42Mbps，全库1秒存储累计10万行PG核对一致、失败/丢弃0；停流/漏点/坏质量/重连/撤权通过。Go全测/vet、Flutter211项/analyze、Windows/Web同源封装、Chrome大小窗口通过。18153（PID75160）及桌面双入口已升级PerfOptimized，PG十一表摘要保持，原1账号/4站点/3文档不变，原浏览器未刷新。后台启动被自动审批拒绝，当前为工具管理的前台服务。长期容量/50渲染浏览器、真实KingIO、原生鼠标/DPI与新安装EXE仍未验或未制作；旧CI不覆盖本工作树。[证据与截图](.ai/docs/performance-optimized-verification.md)。

2026-10-28 DISCOVERY-SELECT done：常用通配符、跨页全选/选择保留及共享按钮美化完成。Go全测/vet、Flutter206项/analyze、Windows/Web同源构建封装、隔离Chrome609项目录及一次保存607项通过。固定18153（PID75464）与桌面双入口升级DiscoverySelect，PG十一表摘要不变，保留原1账号/4站点/3画面；原浏览器未刷新。工具合成星号抬键位置异常已定位SDK映射，真实键盘/原生DPI及现场未验；未出新安装EXE。[验证记录](.ai/docs/discovery-selection-verification.md)。变量归属、设备控制与保存/应用语义保持。

2026-10-28 RUNTIME-UI done：保留GIS，其他运行页采用深蓝导航/浅色内容；重整工艺目录、独立数据站点范围和窄屏抽屉/全部页面入口，切站留在当前数据页；修复目录按钮及低高度台账列表。Go全测/vet、Flutter201项/analyze、Windows/Web同源构建封装及Chrome大小窗口/台账详情/GIS通过。固定18153（PID59600）及桌面双入口升级RuntimeUI，PG十一表数量/摘要不变，原1账号/4站点/3画面保留，原浏览器未刷新。未新增安装EXE；原生鼠标/DPI、现场与用户视觉评审仍待验。[验证记录](.ai/docs/runtime-ui-verification.md)。

2026-10-28 EQUIPMENT-01 done：独立设备台账按站区/小站归档，基础信息、自定义属性、图片及搜索筛选；取消人工在用/维修填报。开发态可选故障/运行两变量及简单公式，Go按需统一判断，运行态只读显示故障/运行/停止、未配置/未知/离线。Go全测/vet、Flutter199项/analyze、Windows/Web同源构建封装、隔离PG重启持久化及Chrome真实绑定/公式保存/状态切换/断网/大小窗口通过。固定18153与桌面双入口已升级dist/Universal-HMI-Equipment-20261028，源码0d3ba318…；备份20261028-093258-equipment，PG十一表数量/摘要保持，原1账号/4站点/3文档保留，无演示数据混入，原浏览器未刷新。Windows原生鼠标/图片文件选择器、真实KingIO及长期容量未验，本轮未出新安装EXE。[验证记录](.ai/docs/equipment-verification.md)。

2026-10-27 GIS-PACKAGE done：确认旧发行包从site-lod复制过期脚本，已绑定/有good数据仍固定显示“数据待绑定”。改为源码目录取GIS文件，纳入发行摘要并逐层校验，JS/CSS及两端地图入口加缓存版本。Chrome验证缺失、62.30→63.40实时变化及重开保留绑定；Go全测/vet、Flutter193项/analyze、Windows/Web同源构建、53项打包测试（11项平台跳过）通过。新含PG修复安装包0.1.0.4已出；旧PG包实际升级、6265应用/3059PG文件、十一表一致、卸载保留/快捷方式恢复通过。18153及桌面双入口升级GISFix，原账号/4站点/3文档保持；原浏览器未刷新。原生窗口实测被自动审批拒绝（blocked by policy），另一台电脑现场未验。[完整验证](.ai/docs/gis-package-verification.md)。

2026-10-27 PG-INSTALL done：无PG电脑离线一体EXE（204243014字节）及PG18.6补充ZIP已生成。Windows部署脚本自动初始化私有PG、备份/迁移昨天v2/v3工程，运行/开发双入口共用后台。真实PG/PowerShell5.1全新初始化、端口冲突、旧数据逐字迁移、失败修复重试、重复启动、v3实际安装升级、原生双入口和卸载保留PG/密钥全部通过；6263个应用文件与3059个PG文件摘要一致。复用已验证登录界面程序，没有修改业务源码；原18153及原快捷方式保持，测试后台已停止。目标服务器现场未验。[部署验证](.ai/docs/windows-lazy-postgresql-verification.md)。

2026-10-27 LOGIN-STYLE done：庄河HTML沿海背景、右侧深蓝/青边登录面板、图标输入、密码显隐与忘记密码说明已适配Flutter；原首次建号/MFA/过期/密码清空契约保持。Go全测/vet、Flutter193项/analyze、Windows/Web构建封装、隔离Chrome实际建号/正确与错误登录/三尺寸通过。固定18153及桌面双入口升级Universal-HMI-LoginStyle-20261027，PG十一表摘要不变，原1账号/4站点/3文档保留；原浏览器未刷新。[验证记录](.ai/docs/login-style-verification.md)。

2026-10-27 GIS-PUBLIC done：GIS仅从公共画面创建，站点仅建工艺图，后端拒绝站点归属GIS保存。当前公共GIS无需迁移；旧站点GIS仅读取且不扩大权限。Go全测/vet、Flutter193项/analyze、Windows/Web同源封装、隔离HTTP及Chrome创建/归属验证通过。固定18153（PID26200）与桌面入口升级至Universal-HMI-GISPublic-20261027，PG十一表摘要保持，原1账号/4站点/3文档不变，原浏览器未刷新。[验证记录](.ai/docs/gis-public-verification.md)。

2026-10-27 EXTERNAL-DATA done（首批KIOHistory适配）：工程级外数据源、日报/明细/趋势画面及独立用户授权已实现，Go原生直连SQL Server，无GOKS/ODBC/现场日报过程依赖。Go全测/vet、Flutter192项/analyze及最终19+5项回归、Windows/Web同源封装、真实隔离SQL Server2019合成505条查询及Chrome交互通过。固定18153（PID41012）和桌面双入口更新至Universal-HMI-ExternalData-20261027，原PG十一表摘要不变，保留1账号/4站点/3画面。现场未连接、原生鼠标/DPI未另验、任意表映射及全区间趋势不在首批；[验证记录](.ai/docs/external-data-verification.md)。

2026-10-27 SECURITY-RAIL done：开发态权限配置入口从顶部移至最左活动栏底部，保留管理员可见性和原配置弹窗。Go全测/vet、Flutter187项/analyze、Windows/Web同源构建封装、隔离Chrome位置与弹窗交互通过。固定18153及桌面双入口已更新至Universal-HMI-SecurityRail-20261027（PID51580），PG十一表数量/摘要不变，保留原账号及画面；[本批验证](.ai/docs/security-rail-verification.md)。

2026-10-27 TEMPLATE-PICKER done：添加画面先选工艺图/GIS，工艺图再用独立表单按公共画面/内置模板分类、搜索和预览；手填名称保留，公共布局同步与本站绑定、内置独立文档语义保持。Go全测/vet、Flutter187项/analyze与最终17项回归、Windows/Web同源封装及隔离Chrome交互通过。固定18153及桌面双入口已更新至Universal-HMI-Templates-20261027（PID71612）；升级前后PG十一表数量与摘要一致，保留1个账号、3份文档。原生鼠标/DPI、现场与公网未验；旧远端CI不覆盖本工作树。[本批验证](.ai/docs/template-picker-verification.md)。

2026-10-27 PERF-5000 analysis_done：5000变量、MQTT每秒一次、50人；用户补充KingIO首次全量/后续变化的发布模式理解，运行页仅50–100变量，开发页可能全量。隔离压测5000值每秒全变化累计95万样本无丢弃；50条鉴权SSE仅32成功/18拒绝，32连接全量负载689Mbps；全库每秒存PG两阶段超时、提交0条。单Chrome5000变量与搜索可用但有短卡顿。建议画面授权订阅+增量SSE、拆元数据、修正纯变化发布的陈旧判定、批量锁外存储；尚未实施。高负载边界不等于现场日常流量，当前不能宣称50人验收通过。[完整分析与证据](.ai/docs/performance-5000-20261027.md)。

2026-10-27 UX-WORKFLOW done：已实现独立建站→站点从公共图添加、公共布局同步和本站集中绑定；统一资源树/创建/预览、保存并关闭、独立折叠和真实空态，删除旧全局目标编辑器/引用即复制及重复活动栏入口。Go全测/vet、实际PG集成、Flutter183项/analyze与最终5项回归、Windows/Web同源封装、隔离Chrome实际流程通过。固定18153及桌面双入口已更新至Universal-HMI-UX-20261027（PID55640）；升级前后PG十一表一致，保留1个已有账号和3份文档。[本批验证](.ai/docs/ux-workflow-verification.md)。远端2026-10-10 f552d81c的38031925060 success不覆盖当前工作树；本批原生鼠标、真实现场和公网未验，不扩大原有验收结论。

2026-10-27 AUTH-PASSWORD done：本机最低5位、公网最低7位，创建/重设/改密与界面提示统一。Go全测/vet（实际PG）、Flutter177项/analyze、Windows/Web同源构建封装通过；固定18153及桌面共享工程已更新至v2（PID48812），实际Chrome确认5位提示。PG十一表数量与逻辑摘要保持，首次管理员仍由用户自行创建。[验证记录](.ai/docs/postgres-verification.md)。

2026-10-27 PG-01 done：本机PostgreSQL18.2专用universal_hmi库已承接18153原工程（PID10380），完整备份及逐项迁移核对通过。自定义角色新增/编辑/批量成员分配/撤销旧会话已实现，开发态“权限配置→角色管理”；桌面运行态与开发态两个图标均复用固定服务。Go全测/vet和实际PG、Flutter175项/analyze、Windows/Web同源封装、真实Chrome权限交互、原生双入口初始页与退出通过。首次管理员由用户自行设置；旧CI不覆盖本工作树。后台启动审批拦截后改为工具管理的前台进程，图标在无服务时的自动启动分支未实测，后续原生启动覆盖归UX-02。[本批验证](.ai/docs/postgres-verification.md)。

2026-10-27 使用对象修订已落实母本/架构：业务用户仅领导层，不增加普通员工角色/工作流。自定义岗位由管理员配置，工程师维护开发及管理员授权边界不变；不凭岗位名称自动授予全站、开发或设备下设权限。

2026-10-27 SECURITY-01第一版完成并更新18153（PID63136）：统一身份、工程师开发边界、独立账号管理、稳定站点/画面授权、MFA和统一KP代码已实施。Go全测/vet、Flutter171项/analyze及最终健康4项、Windows/Web构建、隔离Chrome账号/范围/TOTP和自动端口通过。原数据备份与前后摘要核对通过，首次账号待用户自行设置，未刷新原浏览器。[完整验证](.ai/docs/security-verification.md)。SECURITY-02记录后续增强，AUTH-DEPLOY仍负责实际联网部署，不据本批测试宣称公网已验收。

2026-10-27 SECURITY-01进入实施：用户最终确认工程师可开发、其他用户不可，并授权开始实施；恢复工程师角色，按后端用户/会话/范围及开发能力→全业务接口与UI→MFA及验证顺序推进，固定18153保留原工程。以下“所有用户均无开发权”是已被替代的历史设计。

2026-10-27 SECURITY-01用户确认约束：所有用户只使用Web/用户端，管理员也无开发权；取消工程师角色，开发编辑/发布能力不可授予，用户服务拒绝开发路由/API/MCP。已修订母本和架构目标，开发环境与用户管理独立；尚未实施代码隔离，18153本机开发预览保持。

2026-10-27 固定入口与安全设计：用户明确要求持续使用18153并保留工程，现已更新最终导航版本（PID43952），原3份JSON摘要及SQLite逻辑内容完全一致，备份完整性ok，原用户浏览器未刷新。[部署证据](.ai/docs/evidence/20261027-page-navigation/deployment-18153.json)。联网安全现状已审查，统一身份/动作+范围授权、MFA、数据投影及审计的目标设计写入[架构母本](.ai/docs/architecture.md#2026-10-27-联网安全与用户权限)，实现跟踪SECURITY-01；没有开放公网或创建实际账号。

2026-10-27 PROCESS-01通用导航与GIS跳转反馈完成：跨站分组、排序、组名展开并回首图、箭头独立折叠；GIS可选择稳定工艺画面目标并保留拖动后的绑定。Go全测/vet、Flutter168项+最终16项/analyze、Windows/Web release、真实Chrome点击与小窗口通过。[证据](.ai/docs/page-navigation-verification.md)。最终隔离预览18157；18153替换被自动审批拦截而未执行。安装包、本次原生鼠标和用户评审未完成，PROJECT-01原open范围不变。

2026-10-26 数据源扫描添加反馈完成：变量管理/新增/来源行三入口，来源扫描、关键字过滤、BOOL/STRING/FLOAT识别与手工确认、目标站批量保存及防重复；KingIO首次全量包零配置可发现。Go全测/vet、Flutter166项+最终4项/analyze、Windows/Web release、真实浏览器和本地MQTT1包250项验证通过；18153预览更新，安装包及真实现场未验。[证据](.ai/docs/point-discovery-verification.md)。不改变PROJECT-01原有open范围。

2026-10-26 桌面端口回退完成：18080 被其他程序占用时自动选择可用回环端口，API/GIS 共用实际地址。Go test/vet、Flutter analyze/162 项、Windows/Web release、v2→v3 覆盖安装、6256 文件核验、占用时 26810 上原生 GIS/工艺图、空闲时 18080、正常退出及卸载保留数据均通过。新安装包 dist/installers/Universal-HMI-MQTT-GIS-20261026-v3-Setup.exe；沿用 v2 数据目录，WebView2 仍独立安装，现场 MQTT 未验。详见[本批验证](.ai/docs/desktop-port-fallback-20261026.md)。

2026-10-26 变量语义核验及 Fork/AI 约束完成：新增“同源跨站乘除、不同周期实际落库、坏质量传播、旧历史冻结、跨站误存拒绝”回归；Go 1.24.7 全测/vet通过。[核验证据](.ai/docs/variable-semantics-verification.md)与架构合同区分底层能力、UI现状和未实现范围。本轮仅文档/测试，PROJECT-01仍open；未实现变量引用反查，不将其标为已完成。

2026-10-26 Windows 安装包完成：冻结已验v2封装为 dist/installers/Universal-HMI-MQTT-GIS-20261026-v2-Setup.exe（约156MiB）；三个桌面/开始菜单入口、卸载保留数据；按用户要求WebView2独立安装。隔离实际安装6256文件核验、GIS/工艺/开发三入口及退出、卸载和数据保留均通过。未签名测试版，现场MQTT未验。详见[安装包验证](.ai/docs/mqtt-trial-20261026.md)。

2026-10-26 PROCESS-01 页签菜单归属完成：菜单与当前公共/站点/GIS/工艺文档对应，切回恢复原功能和GIS预览状态；修复加载中默认GIS入口竞态。Flutter analyze/160项、Web/Windows release和真实Chrome切换通过，18153已更新；[验证记录](.ai/docs/screen-workspace-verification.md)。本轮未修改后端或打包dist。

2026-10-26 PROCESS-01 GIS弹窗点击修复完成：地图输入跟随所属路由是否位于最上层，覆盖外部确认、菜单及嵌套弹窗；预览地图独立处理。真实Chrome鼠标、文本输入与小窗口检查通过，Flutter analyze/158项及Web/Windows构建通过，18153已更新；[验证记录](.ai/docs/screen-workspace-verification.md)。Windows原生弹窗交互仍需独立实测。

2026-10-26 原生 GIS 临时包 v2 完成：Windows EXE 内嵌离线GIS与工艺图，支持客户GIS/客户工艺/开发配置三个启动入口，独立测试工程首次加载无绑定示例。Go test/vet、Flutter analyze/157项完整测试及最终10项回归、Windows/Web release通过；实际原生GIS浮窗62.30°C、工艺图61.2→62.3更新、启动首页保留和退出脚本清理通过。现场MQTT未验；直接EXE后台残留仍归UX-02。产物dist/Universal-HMI-MQTT-GIS-Trial-20261026-v2.zip，详见[临时包验证](.ai/docs/mqtt-trial-20261026.md)。

2026-10-26 PROCESS-01 GIS透明导航点击修复完成：平台DOM事件隔离层防止菜单点击落入地图iframe；真实鼠标在宽/窄布局切换四菜单并继续拖图通过。Flutter analyze/155项、Web/Windows release通过，18153已更新；见[导航点击验证](.ai/docs/screen-workspace-verification.md)。

2026-10-26 临时交付：用户要求的 MQTT 站点/数据绑定测试包位于 dist/Universal-HMI-MQTT-Trial-20261026 及同名ZIP；Go test/vet、Flutter analyze/155项、Windows/Web构建、实际EXE启动及同包Web通过。UX-02补充真实缺陷：Windows窗口exit0后自有后端仍运行，临时包附已验证的精确路径停止脚本，生命周期修复仍open。本机无Mosquitto，现场MQTT/真实点位绑定未验；证据[临时包验证](.ai/docs/mqtt-trial-20261026.md)。

2026-10-26 GIS浮窗绑定完成：五项指标可从共享变量库按稳定ID跨站选择、搜索与解除；随GIS独立草稿/revision保存，拖动保留绑定。浮窗经现有SSE展示真实数值/单位及缺失、坏质量、陈旧、离线状态。Go全测/vet、Flutter analyze/155项/Web/Windows release通过；真实Chrome选择/保存/拖动/重开/连续更新及断开服务显示离线通过。18153更新为新后端/Web（PID8948），原已保存画面摘要未变，用户浏览器未刷新；刷新前先保存会话草稿。证据见[GIS绑定验证](.ai/docs/screen-workspace-verification.md)。独立多工程/变量反查不在本批。

2026-10-26 PROCESS-01 编辑态多画面页签完成：按画面ID保留工艺/GIS独立草稿，重复打开激活原页签；同站多图、新建/导入/引用/副本不替换已开画面，关闭脏页签需产品内确认。Flutter完整153项、最终15项回归/analyze及Web/Windows release通过（源码1ddf406a…）；实际Chrome三页签、改名未保存切图恢复和撤销通过，已保存的两张示例图revision未变。内置18153开发预览保留工艺/GIS两页签。证据见[多页签验证](.ai/docs/screen-workspace-verification.md)。草稿仅会话内保留，未增加刷新恢复能力。

2026-10-26 PROCESS-01 GIS反馈完成：海面常开，无全屏按钮，淡色图标从当前镜头平滑重播；GIS透明顶部导航。analyze/6项回归、Web/Windows release和实际Chrome首帧连续性、重复重播、导航切换通过。证据见[GIS重播追加](.ai/docs/screen-workspace-verification.md)，现场/原生GIS边界不变。

2026-10-26 PROCESS-01 最新反馈已完成：客户GIS满幅/无来源浮条，工艺站区菜单美化并移除图外说明和底栏；开发端只读预览，GIS站点仅编辑态修改、独立草稿显式保存。Go全测/vet、Flutter150项+最终12项回归/analyze、Web/Windows release与18153实际Chrome交互通过，证据见[本批追加](.ai/docs/screen-workspace-verification.md)。真实点表/站址、原生GIS和用户评审继续跟踪；未提交工作树不由旧CI覆盖。

2026-10-26 PROCESS-01 本批完成：原浅色整套工作台归开发端，活动栏只切换相邻面板，具体资源再打开中央内容；客户运行页无开发入口，工艺菜单为站点→画面。GIS可手动添加公共/站点实例，每次进入重播6秒飞入，嵌入页禁用拖动站址。运行内存值改SSE。Go全测/vet、Flutter149项及最终18项回归/analyze、Web/Windows release通过；独立18152实际Chrome与内置预览通过，详见[本批验证](.ai/docs/screen-workspace-verification.md)。点表/真实站址、原生GIS及用户评审继续跟踪，旧CI不覆盖本批。


PROCESS-01 导航高度反馈：桌面顶部76px、窄屏112px、图标48px；145项测试/analyze、Web/Windows构建和两尺寸实际页面通过，已更新18151预览。

GIS-01 2026-10-26：Web首页GIS已接入供热导航，18151同源gis/map.html；6秒首入/切回直达/移出自动收起浮窗通过。地图仍为示意站址/未知数值；原生WebView、KP现场、真实站址与生产验收待后续，保持production_open。证据 examples/gis-flight/verification.json。

PROCESS-01 2026-10-26导航外观补充：顶部/侧栏六张透明生成图标已接入，选中与未选中状态由代码实现；实际Chrome三尺寸、站点搜索切换及悬停通过。外观实现及证据并入[供热监视验证](.ai/docs/heating-monitor-verification.md)，用户视觉评审与点表接入继续跟踪本项。

2026-10-26 GIS浮窗：白色工业信息面板、冰蓝标题区/同款站标/细蓝边框、深蓝标题，一次/二次侧供回水双列分组，压力独立；保留数据待绑定状态与拖动位置。真实Chrome悬浮显示、360×420容器内边界/滚动检查通过，控制台无错误。

PROCESS-01 2026-10-26：增加供热深蓝只读监视页和94元素/27未绑定值参考模板，使用现有编辑器；修正换热器管孔层次，分离电子温度表/压力传感器，新增真实金属水箱及角式泄压阀素材。Flutter144项/analyze、Python3项、Windows/Web构建与独立Chrome新建保存重开/切站/三尺寸通过。18151可查看；真实点位、GIS接入及用户视觉验收仍待后续，本项保持in_progress。证据见[供热监视验证](.ai/docs/heating-monitor-verification.md)。

2026-10-26 GIS站区与开屏：用户透明PNG替换原站区图标；自动6秒飞入，删除地名标题/中心庄河标记/底部飞行面板；最后减速段5.4秒起90ms错峰560ms生长回弹，仅入场一次。stations.json按稳定ID配置示意坐标，悬浮浮窗/点击固定/本机拖动位置编辑；真实站址与实时数据仍待接入。Chrome约6.00秒落地、6站顺序动画/悬浮/固定/HTTP验证通过，无控制台错误；仅18149独立展示。

GIS-01 2026-10-26海面：同日SCL沿岸遮罩、双尺度动态法线/缓涌、视角高光和可关闭的近景材质；抵达后保持动态壁纸效果。严格归独立展示，无业务接口改动。验证及现场边界见examples/gis-flight/verification.json。

2026-10-26 GIS轻量画质迭代：新增NASA东北亚2048纹理（不到1 MB传输，约16 MiB解码），弥补全球至辽东清晰度断档；非对称对数高度曲线提前抵达区域，转向与缩放同步落定。原始大图仅构建缓存，来源/摘要/调色入region-source.json。无云层；生产目标机仍待验。

2026-10-26 GIS过渡修正：保留连续NASA底图，旋转视野进入覆盖范围再显现区域瓦片，运行时3层/文字10Hz。暖缓存1367×770两次RAF P95约16.8ms，不作目标机保证。用户否决穿云贴图，已从源码/运行页/资源撤除；后续先参考游戏与Earth Studio镜头方案，不再自行加云。

GIS-01 2026-10-26视觉迭代：NASA真实地球影像/侧光/本地装饰星空，默认8秒、落地逆时针90°；Chrome实际完成与北向屏幕左侧验证通过。生产接入仍待后续，详见演示verification.json。

更新：2026-10-13。PR #1–8 已合并。上一轮用户指定五项基础能力及精确 head 验收已完成；登录/MCP本轮已完成隔离验证，PR #10最终head检查及合并以远端为准，证据见 `.ai/docs/focused-functional-tests.md` 与 `.ai/docs/v0.1.md`；母本仍为 `agent.md`。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| GIS-01 | demo_verified / production_open | 地球至庄河动画；庄河保留10米细节、大连降采样、全球模糊；本地影像/可嵌入/生产接入准备 | 2026-10-26 独立18149实际Chrome播放/暂停/进度/三尺寸通过；4797张本地瓦片、HTTP边界与资源通过，无外网HTTP请求和console error/warn。源码/许可/重建/证据见 examples/gis-flight/README.md 与 verification.json；技术演示完成，真实站点、KP/Flutter接入、高清图源及目标机生产验收未完成。未改18139/11005，基点CI不覆盖本批 |
| KP-04 | done | KP登录慢定位、构建资源重验证缓存与快速打开接法交付 | 真实KP认证约48ms，两次定时器额外等待约2.03秒；Go全量test/vet/Windows服务build、18项KP脚本passed。18139当前PID70860/cache binary，会话/权限/静态304/重复启动与原三画面摘要通过，真实KP容器工作区显示。浏览器重复传输25.45MB→16.44MB，字体仍完整重传；未测实际改配置后的端到端时间。快速调用示例及KS_HELP说明已交付，KP打开事件配置由操作方应用，继续归AUTH-DEPLOY。见 .ai/docs/kp-performance-verification.md；本批工作树修改不由旧CI覆盖 |
| KP-03 | done | 用户授权的18139本机KP联调配置与持续后台启动 | 私有单用户operator/实际11005来源、public-origin/kp-config/kp-local-trial；隔离与实际bootstrap/redeem/业务读取/自有测试退出通过，/kp/及资源200，匿名401/未知用户与来源403。独立Chrome工作区与票据清除已验，无error/warn；原三张画面摘要不变，当时PID68856，重复启动复用；后续更新运行见KP-04。当前仅回环用户名白名单试验，真实身份/多IP/LogOff仍归AUTH-DEPLOY。证据 .ai/docs/kp-local-trial-verification.md |
| KP-02 | done | KP 容器 HTTP(S) 空白页与脚本导航兼容 | 2026-10-13 独立 Chrome 跨端口 iframe 复现相同拒绝连接，确认本机空白页 frame-ancestors self 拦截，修复后实际 frame=blank.html、无控制台拦截。正式KP白名单保持；Go全量test/vet/Windows服务build passed，当时18139 PID68556/health=ok/blank GET-HEAD200-POST405，三张画面摘要未变。旧HTTP200不当作嵌入成功证据；启用前KP配置未启用、bootstrap404，后续本机联调启用见KP-03，真实KP/身份接入归AUTH-DEPLOY。本轮工作树修改，基点CI不覆盖。见 .ai/docs/kp-blank-verification.md |
| KP-01 | done | KP 登录壳、可信身份验证端口、一次性票据、Web/KP双通道、当前实例退出与多 IP/NAT 并发 | Go test/vet（150 个顶层测试）、Flutter analyze/140项/75文件只读格式、KP脚本17项、Windows/Web release+verify-only passed，源码919830a4…。独立 Chrome 同账号两窗口单独退出/另一窗口刷新、LogOff false→true、viewer读200写403、焦点关闭/Tab回归通过；本机 race 环境不可执行，提交 CI 独立核查。实际多IP/KP/现场由 AUTH-DEPLOY 继续验收；合同和证据 .ai/docs/kp-bridge.md、.ai/docs/kp-bridge-verification.md |
| PROCESS-01 | in_progress | 免费工艺 SVG、共享透明 PNG、通用开发页、新建模板、参考供热站蓝图/组件适配；属性提交、左键绘制、四边缩放；管道拼接/撤销/角度、伪3D/圆角/弯头、参考线、箭头分布/动画/反向/条件、模板绑定隔离；素材端口随等比内容框与旋转对齐 | 最新素材修复 Go test/vet、Flutter analyze/131项/68文件只读格式、Python3项、Windows/Web release+verify-only passed（源码c8ecdd90…，基线10af848）；四自绘设备×四方向实际像素连接 passed；真实 Chrome 右边拖宽/新管吸附/撤销、960×480与640×360嵌入连续 passed。此前管道180a2896…/128项及文字/四尺寸/透明PNG证据保留。18139仅更新Web，三张用户画面字节不变，未刷新用户页。10af848 CI38022212602 / 生命周期38022212630 success；本修复新head与用户评审以 PR #14 为准。证据和边界见工艺画面说明；保存解码诊断11类与管道全部字段HTTP回归、实际v3保存重开及Go/Flutter131项/Windows-Web构建通过；18139后端已更新，用户原文件不变。原截图失败请求待用户重试，具体根因尚未确认。保存证据见工艺画面说明 |
| INSTALL-03 | in_progress | Windows/Linux/macOS 原生安装器及同包 Web，广泛回归与实际截图 | 对应 OS CI 安装/更新/卸载、包内 Web 字节核对；Linux 实际安装展示；不声称未执行的原生人工测试 |
| UX-03 | open | 原生历史页进入时刷新旧计数的可见性 | 当前点击筛选显示真实结果；不影响已证实的后台落库 |
| UX-02 | open | Windows 人工交互/DPI/多屏/生命周期 | 独立 Windows 真机证据；Linux 证据不替代 |
| PROTOCOL-01 | open | 真实设备厂商协议、ACK/读回 | 本地 broker 模拟不冒充现场验收 |
| SCALE-01 | open | 长期负载及流畅度 | 已有 5来源/30站/15000点证据；total P99 约60ms，不承诺60FPS |
| PROJECT-01 | open | 独立多工程隔离与切换 | 当前为单本地工程、多站 |
| AUTH-DEPLOY | open | 操作方证书/账号配置及实际网络验收；KP可信身份与壳脚本对接 | 统一身份下的站点/画面范围及TLS/MFA/KP隔离回归已验；真实verifier须提供可信MFA及认证时间并映射稳定user_id，实际证书/多IP/NAT/LogOff/后台定时器/OT及外部入口防护仍待验。18139旧KP用户名试验保留全工程旧模式，18153已为本机统一身份模式，均不自动公开；见 .ai/docs/security-verification.md、.ai/docs/kp-bridge.md |
| SECURITY-01 | done | 第一版统一身份与站点权限；工程师可开发，其他用户仅Web/用户端 | 多用户/Argon2id/TOTP/恢复码、会话版本撤销、角色+稳定站点/额外画面、业务及MCP范围裁剪、文件owner/执行复核、控制发送前授权、正式KP统一Actor及Flutter管理已实现。Go全测/vet、Flutter171项/analyze+最终4项、Windows/Web及实际Chrome通过；固定18153首次建号就绪，原JSON/SQLite摘要不变。完整目标尚有SECURITY-02和AUTH-DEPLOY，见 .ai/docs/security-verification.md |
| SECURITY-02 | open | 安全基线后续增强与运行防护 | Passkey/OIDC、邀请及泄露口令库、端类型策略、局部工程师发布、关键动作双人批准、独立服务身份管理、完整CSP来源策略、外部审计/轮换/容量告警、加密备份恢复、代理信任链及实际安全压力/渗透验收尚未实现或未验。当前同机审计/密钥不冒称不可篡改或独立托管；按实际部署风险实施，完整目标继续以架构母本为准 |
| BASE-01 | open | SPT 独立 Lite 来源核实 | 不把参考文档称为源码迁入 |

已解决的旧 ENV-01 和 RELEASE-01 不再作为当前阻塞。新一轮成功只以本轮测试及最终提交为证。

登录/MCP已完成项的详细证据在 [.ai/docs/auth-mcp-verification.md](.ai/docs/auth-mcp-verification.md)，包含独立复核问题与修复，不作为新的重复活跃项。

虚拟点延迟恢复已定位并完成本地/独立红绿回归，原始断言不放宽；最终修复PR门禁与失败记录见 [.ai/docs/virtual-recovery-verification.md](.ai/docs/virtual-recovery-verification.md)。
