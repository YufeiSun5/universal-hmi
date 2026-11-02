# 当前上下文

2026-11-02 SECURITY-MOBILE-v20 in_progress：本轮已实现真实设备mTLS（含恢复握手、当前审批和归属绑定）、跨通道会话隔离、撤销活连接检查、Coraza3.8.1/请求侧CRS4.30.0、有界限流/暴力登录拦截与持久15分钟封禁、本机证书审批/解封界面，以及原生Java Android只读端。Go1.27.3全test/vet和私有依赖缓存校验通过；Flutter461通过/2浏览器跳过且analyze通过；Android5项JVM测试（含真实回环→mTLS、cookie隔离/错误pin/SSE）及签名release构建通过。fresh许可证封装缺失已修复为46实际Go运行模块与规则许可证可重复组装；Windows/Web fresh重建、完整EXE与保留升级验收仍进行中。公网地址端口可改、默认关闭；用户禁止当前探测现场，18153与真实工程未改。真机Keystore/WebView及真实公网部署未验；全库旧备份会恢复历史审批，恢复后必须保持公网关闭、核对撤销再验收。

2026-10-30 GIS-ZONES-UX-v19 done：GIS站公共数据＋有序分区、工艺/公共GIS多通配绑定搜索、变量卡片名称/站点/单位完整换行完成。Go全test/vet、Flutter289项/analyze、fresh Windows/Web/Go同源4ed187f9通过；完整EXE0.1.0.19，227682820字节，SHA256 4fa559d5eed0c3a9af6dc9f896a93c1efbaa5da5690ea0fa83e045c6c595c06f。隔离v18→v19升级11表/5019点/31图、来源/绑定/设备资料图片与导航保持，PG3059/GIS5204核验。真实Chrome改名/排序/保存重开、多通配绑定、四区1920两列/600单列滚动、单区及长卡片1920/850通过；隔离卸载保工程、快捷方式恢复与18084/55436释放通过。18153/现场未动，原生完整手工与多DPI未验。保留升级无需重导，无新增活跃子任务。[产物与验收](.ai/docs/gis-zones-v19.md)。

2026-10-30 ICON-VARIABLE-UX-v18 done：同系列台账PNG、统一变量通配/多选及窄窗命令栏/资源树抽屉/工具栏换行完成。Go全test/vet、Flutter285/analyze、fresh Windows/Web/Go同源422f00f0通过；完整EXE0.1.0.18，227663754字节，SHA256 1e754ce5d022dce069362d7a35395a46a1f2da8f49b56711692cfe51b789ea0d。最终v17→v18隔离升级11表/5019点/31图/设备资料图片与菜单保持，PG3059/GIS5204核验，卸载保工程/快捷方式恢复/端口释放通过。实际Chrome850×600、884×561、1920×1080搜索批选/抽屉/曲线超限通过；Windows96DPI最小900×600与正常退出通过。自动化fill星号keyup位置错误已捕获，type_text正常，未改应用键盘逻辑；不声称零控制台错误。18153/现场未操作，手工原生全流程/多DPI未验。完整EXE已按用户要求先交付，保留升级无需重导，当前无新增活跃子任务。[产物与验收](.ai/docs/icon-variable-v18.md)。

2026-10-30 历史v17候选（已由v18接续）：用户要求台账图标与原PNG系列统一，并确认扫描添加、变量列表、曲线/关注三个入口都支持通配符、多条件与多选。root接入生成PNG、统一匹配器及独立批选，正在专项/全量验证和完整EXE构建；尚未交付。保留升级、不操作18153/现场、不重导工程。唯一进度见AI_BOARD。

2026-10-30 最新交付EQUIPMENT-UX-v16：设备图标原创重设计，独立GET/PUT /api/v1/equipment-navigation及可编辑分组/目标/顺序，Device.photo_fit三模式，图片Future/字节缓存、宽屏详情与列表/详情修订同步完成。Sol后端/发行、Terra UI、root图标与审查。Go全test/vet、Flutter279/analyze、fresh Go/Windows/Web同源6e880a04通过；完整EXE dist/installers/full-20261029-v16/Universal-HMI-20261029-Full-v16-Setup.exe，0.1.0.16，225149836字节，SHAf52bf7aaa2ffd752c79c316546280b2aaf44f9cfaf52a402a7c902a0607c8b39。隔离v15升级11表/5019点/31图及绑定/来源/工艺导航/旧设备raw JSON/PNG与JPEG字节保持，不自动创建新菜单，PG3059/GIS5204核验。root实际1920×1080多/单设备、长参数、三图片模式及34秒同图1请求，菜单改名上移保存重开、运行搜索折叠、850×600档案弹窗通过；无原生GUI/现场或浏览器故障恢复实测。隔离卸载保工程、四快捷方式恢复、18084/55436释放完成；18153未操作，末次只读未见监听，不声称在运行。无需重导工程，无ZIP，无活跃子任务。[证据](.ai/docs/equipment-ux-v16.md)。下方v15及更早为历史交付。

2026-10-30 最新交付PROCESS-EDIT-v15：Sol/Terra实施、root审查。已补空白拖动框选、Shift追加、Ctrl+A、批量移动/复制/删除和撤销，修复外侧手柄优先级；箭头修复系统减少动态错误停用业务流动，保留质量/条件门槛与隐藏暂停。Go全test/vet、Flutter275全测/analyze、fresh Windows/Web/Go同源c39c7f95通过；完整EXE dist/installers/full-20261029-v15/Universal-HMI-20261029-Full-v15-Setup.exe，0.1.0.15，225111566字节，SHA4125bf17b8e153f865debc654a25f5e7244c3a9677490813a2bbe368b84e9c42。v14隔离升级11表/5019变量/31画面保持，PG3059/GIS5204核对通过。普通资料沿用v14，无ZIP，无需重导。浏览器实际验收被Computer Use无法识别Windows浏览器URL的安全检查中止，原生GUI/现场未验；不能以自动回归冒充实机全验收。隔离清理、卸载保留工程、原快捷方式恢复及端口释放passed。18153/现场未操作，无活跃子任务。[证据与限制](.ai/docs/process-edit-v15.md)。以下v14及更早版本为历史记录。

2026-10-30 历史交付 v14：Sol/Terra实施、root审查。开发站仍平铺，客户端14父28叶菜单；28主图删右侧补充栏，保留主图386确定绑定/396待核位置，313唯一已有点匹配，支持同一导入身份精确批量更新。Go全测/vet、Flutter270测试/analyze、同源Windows/Web/Go构建、最终EXE隔离升级与PG5019保留、28原图ID及实际point_id保持、重复提交通过；root客户端菜单/搜索/切换和大小窗口视觉通过。EXE dist/installers/full-20261029-v14/Universal-HMI-20261029-Full-v14-Setup.exe，0.1.0.14，225113533字节，SHA e48c9607bf1d5a58655e81b4e55b307cc62d8a78207ddf33bbbee587eac2bc04；JSON outputs/process-navigation-v14-20261030/创建画面与绑定-主图父子导航-v14.json。保留升级、不自动清理/分站，无ZIP。用户截图误把325点批量指向中心站东南区，已指导清空后点击“选择筛选内单站建议”，不用“设置筛选结果目标”。最终开发态/导入UI实看、原生GUI及现场未验，截止后停止追加验证。隔离清理完成，原快捷方式恢复，18153/现场不动。无活跃子任务；[核验](.ai/docs/process-navigation-v14.md)。以下版本均为历史。

2026-10-30 CROSS-STATION-DISPLAY / OWNERSHIP / INSTALL-FULL-v13 done：Sol/Terra实施、root审查。跨站数值/箭头遗留限制修复；新增按工艺画面分站、原子仅Station保存、备份/回退、规则存储依赖闭锁及运行旧归属禁删。v13保留升级不调用工程重建，现有变量无需重扫或重导图。Go全测/vet，Flutter266全测及最后6专项/analyze，fresh Windows/Web/Go同源e59954b5通过；PG5019升级11表保持、325点迁移回退再迁移、root浏览器42.5箭头及mock迁移/Apply通过。完整EXE dist/installers/full-20261029-v13/Universal-HMI-20261029-Full-v13-Setup.exe，225135443字节，SHA256 64e96f68b31df2e61f80654dc862afbe762441d697cdda605cbfed9f65efafe3，无ZIP。测试历史过期清理首次失败及修正证据保留。隔离卸载保留工程、端口停止、原快捷方式恢复。18153及现场未动，现场MQTT/公网及本轮原生GUI未验。当前无新增活跃子任务；最新交付以v13为准。[综合验收](.ai/docs/cross-station-ownership-v13.md)。

2026-10-29 SCANNED-NUMERIC-MATCH：现场扫描5019变量已有值；导入期望INT与扫描FLOAT冲突。已交付 outputs/process-scanned-numeric-20261029/扫描变量后导入工艺-数值类型适配.json（SHA256 986d5fc915825b321ec141851b07485afb0856e24befe0fe2f006569de01670d），仅56个类型匹配期望及来源映射变化，不修改已有变量。独立5019夹具旧56冲突、新0剩余、28图471原ID引用通过；现场仍需预览。无需安装包。Sol实施、root审查。

2026-10-29 SERVER-MAINTENANCE-FAILURE / INSTALL-FULL-v12 done：现场只读报告定位v11严格ownerSID校验拒绝已提升Administrator的Administrators组owner工程，尚未进入备份清理。Sol修复受限组owner授权及早期脱敏诊断；Sol发行、Terra隔离验收、root审查。v12完整EXE dist/installers/full-20261029-v12/Universal-HMI-20261029-Full-v12-Setup.exe，0.1.0.12，225091023字节，SHA256 912bedd0f2bb72796474f3478de06e224f14fecf23cc07e70a663d6db4a7c09b。12项脚本回归、两次Inno早期失败42/日志不覆盖、最终v11→v12升级/显式重建/冷备恢复/重装/卸载保留通过；复用9c50应用，仅更新部署。源工程ACL不改，MQTT/GIS/身份/历史保留，迁移ID仍process-rebuild-v10。原快捷方式恢复，隔离端口释放，18153未改。真实提升管理员令牌/现场安装未测，ACL策略模拟与普通用户实测分别计证。当前无活跃子任务，最新交付以v12为准。[验收](.ai/docs/windows-maintenance-admin-v12.md)。

2026-10-29 SERVER-REBUILD-v10 / INSTALL-FULL-v11 done：Sol/Terra实施，root审查。完整EXE dist/installers/full-20261029-v11/Universal-HMI-20261029-Full-v11-Setup.exe，0.1.0.11，225088911字节，SHA256 2cc1a11563570924368d3354da91d0f68edbb2074db6c44b5cbe54ddf0ea3426。谨慎删站、原子批量删变量、MQTT扫描后match_existing完成；重建先完整冷备，保留MQTT/GIS/身份/历史，固定process-rebuild-v10标记避免重清。Go全测/vet、Flutter263项/analyze、Windows/Web构建、最终EXE隔离v9→v11升级/重建/实际恢复/重装/卸载保留通过；root实际Web删除交互通过。v10退回后v11修复部署，复用本轮9c50应用。未改18153或现场服务器，现场MQTT及本轮原生GUI未验。原快捷方式恢复、隔离端口释放，无活跃子任务。最新交付以v11为准，旧ZIP仅历史记录。[验收](.ai/docs/server-rebuild-v10-verification.md)。

2026-10-29 INSTALL-FULL-v9 done：最新交付改为完整安装EXE，所有资料均普通文件，不再给用户压缩包。dist/installers/full-20261029-v9/Universal-HMI-20261029-Full-v9-Setup.exe，0.1.0.9，215991875字节，SHA256 8362ff33c39bd2d5fd82449749fa8a0ea495684b906f30a73e013b59beb1bf06。复用ClientHistory源码a4407c04…应用，PG18.6内置，KingIO 28图/385变量六文件已展开。Sol封装、Terra隔离v8→v9安装/覆盖/卸载，root审查；6297应用/3059PG字节、11表摘要、旧测试账号、HTTP Web/GIS、保留PG/工程/密钥通过。原四快捷方式恢复，18153 PID3908/project.json保持；无实际工程导入或现场连接，原生GUI本轮未重验，WebView2仍前置依赖。以下旧ZIP和“未出新EXE”仅为历史阶段，当前以v9为准。[记录](.ai/docs/windows-full-release-20261029-v9.md)。

2026-10-29 CLIENT-HISTORY done：客户端业务仅GIS、工艺画面、设备台账、历史；历史复用外部SQL日报/明细/趋势，内部历史、变量及存储工具保留开发端。工程师runtime同样隔离内部请求，外部失败不回退。Terra实施、Sol发行、root审查及实际Chrome验收；Flutter完整253项及最终专项11项/analyze、Windows/Web同源构建、隔离SQL查询与停机错误通过。固定18153已更新dist/Universal-HMI-ClientHistory-20261029（PID3908，工具前台session48083），四桌面快捷方式已更新；备份20261029-172730-client-history，PG11表、原账号/站点/文档/审计、GIS5204文件和远程配置保持。新桌面ZIP207176355字节，SHA256 4eea33da4b98405744ff413cbf24b4323ffad17e333e5052b8b2d54539e59868，含最新KingIO绑定资料；未新出安装EXE，旧v8不含本轮客户端改动。测试18164/SQL容器/Chrome已关闭，原用户窗口保持，现场和原生GUI本轮未重验。[验证](.ai/docs/client-history-verification.md)。

2026-10-29 KingIO完整绑定包已交付：outputs/process-kingio-bound-20261029.zip，推荐导入包内import-request.json。28图、385只读MQTT定义、471已配关系、441待核位置；329 FLOAT/56 INT，source_path为KIO完整名、topic空，12原始KIO分组作默认新变量归档，60共享点不复制。Decode/385 Normalize/隔离实际28图385变量471引用/重复幂等通过，root独立核对路径、类型、分组及value引用通过；16出口压力均落按实际量义增加的original节点。真实工程未写，KingIO未修改或连接。只需选择真实KingIO来源（本机当前0source）；目标HMI已有同身份或同站同名变量时明确引用。旧348包和“必须拿现场已有变量ID”前提被本包替代；v8无需因资料变化重编译。

2026-10-29 绑定方案纠正：用户指出已有KingIO对照表。重新核对原始交接与4688项Tag.db：471个明确位置、385个唯一KIO完整名（329 FLOAT、56 INT），12个来源归档组，60变量跨画面站共享。旧348数量误限于KS服务器访问路径；KingIO接收按Objs.N匹配，source_path应是KIO完整点名，topic允许空。现有transfer显式create可生成稳定新ID，不需要现场已有变量ID。正在生成完整包并隔离验证，现场只需选择真实KingIO来源；本机0来源不伪造broker。此决定替代下条“必须现场变量目录”的前提，模糊候选仍留空。

2026-10-29 用户在v8交付后追加要求代理代绑，不希望现场逐图元处理。正在按直接IO/明确文档依据准备绑定关系；已核对本机18153仅3个manual点、0来源，没有可引用的KIO身份。470个完整路径/图元记录中348个证据明确、122个仍是模型推导候选。真实绑定需要现场变量导出目录；既有v8与真实数据保持。活跃任务改为PROCESS-BINDING，不将空绑定交付视为此追加要求已完成。

2026-10-29 PROCESS-STATION-BUILD / INSTALL-FULL-v8 done：按用户批准方案由6.1 Sol/Terra实施，主代理审查并完成交付。28张空绑定工艺图、匿名双泵模板、画面/变量/绑定独立及完整JSON、Excel三表、CSV；276个候选和912个待绑位置由现场确认。Go全测/vet、Flutter249项及末轮14项/analyze、实际HTTP/Chrome、全新Windows/Web构建和v7→v8隔离覆盖安装通过。v8安装包0.1.0.8内置PG18.6，216466987字节，SHA256 d37ea03b570dd6634d367bdefee976493dca6225f2e8f98de06b64e8540129d7；6339应用/3059PG文件验证，原测试账号、11表与卸载保留通过。固定18153及四桌面入口升级dist/Universal-HMI-ProcessTransfer-20261029，源码524842ae…；备份20261029-162619-process-transfer，真实1账号/4站点/3文档/25审计和全部11表、5204个GIS文件保持。新服务由工具管理的前台会话22529提供；旧窗口未关闭，真实工程未导入测试图/候选。现场KIO、真实公网NAT及本批原生GUI未验。资料outputs/工艺图与变量绑定导入资料-20261029.zip，当前无新增活跃子任务。[功能验收](.ai/docs/process-transfer-verification.md) / [发行记录](.ai/docs/windows-full-release-20261029-v8.md)。

2026-10-29 INSTALL-FULL-v7 done：交付完整离线安装包0.1.0.7，内置PG18.6及已验PublicRemote应用，215852816字节，SHA256 7623809b…。6.1 Sol封装，主代理审查并实际验证v6→v7、6289应用/3059PG文件、十一表保持、旧账号登录、Web/GIS字节及卸载保留数据。原快捷方式已恢复，真实18153未改。应用未再次编译，安装来源独立计证；公网默认关闭、IP留空。更新前分别托盘退出两端，再停止后台后覆盖安装。当前无新增活跃子任务。[记录](.ai/docs/windows-full-release-20261029-v7.md)。

2026-10-29 PUBLIC-REMOTE done：可配置自签HTTPS、公网与本机同工程双监听、客户端远程连接/公开证书固定信任、GIS受限代理及独立远程双入口完成。6.1 Sol/Terra实施，主代理审查并修复TLS拒绝断连、执行最终实包验收。Go全测/vet、Flutter242项/analyze及最终4项回归、Windows/Web同源构建封装、真实TLS业务/SSE/拒绝/退出、桌面生命周期和4次正常退出0通过。18153及本机双入口升级dist/Universal-HMI-PublicRemote-20261029，源码e2a8499a…；备份20261029-134620-public-remote，PG十一表摘要和5204个GIS文件保持。IP留空、公网默认关闭；新增远程开发/运行入口。真实公网/NAT、远端GIS完整渲染、长期连接及可选SCM现场安装仍待验；未制作新安装EXE、未关闭原窗口或刷新页面。[配置](.ai/docs/public-remote-guide.md) / [验证](.ai/docs/public-remote-verification.md)。当前无新增活跃子任务。

2026-10-29 APP-ICON done：内置imagegen生成原创深蓝/银白/青色连通标志，6.1 Sol实施，主代理母版及32/128px审查通过。Windows程序/窗口/托盘、双快捷方式、Web图标统一替换；macOS/Linux资源同步。analyze、Windows/Web构建、EXE七档资源逐字节、18153七HTTP响应与5208保护文件hash通过。当前DesktopLifecycle stage按图标覆盖记录升级，未重启后台或关闭旧窗口；未重跑业务全测/Go及未出新安装包。[验证](.ai/docs/app-icon-verification.md)。

2026-10-29 DESKTOP-LIFECYCLE done：Windows同工程开发/用户端各自单实例、重复启动唤回、关闭到托盘/最小化到任务栏及工艺/GIS退出草稿保护完成。两项行为均获用户确认。6.1 Sol/Terra实施，主代理审查、退回修复原生析构重入异常0xC000041D，再重建实测通过。Go全测/vet、Flutter235项/analyze、最终C++修正后11项定向回归、Windows/Web同源封装通过；原生并发/跨端/跨工程/隐藏恢复/崩溃恢复、4次正常退出0及真实取消/保存退出0通过。固定18153及双入口配置升级dist/Universal-HMI-DesktopLifecycle-20261029，源码51e704ba…；备份20261029-120525-desktop-lifecycle，PG十一表完全不变（1账号/4站点/3文档/24审计），5204个GIS文件逐字保留。旧窗口未关闭或刷新，用户需自行重开新版。共享服务不归客户端所有；裸EXE无endpoint时仅兼容单端，不与正式入口混用。物理托盘鼠标/Explorer重启/完整DPI/现场未验，未制作新安装EXE。[验证](.ai/docs/desktop-lifecycle-verification.md)。

2026-10-29 PROCESS-VARIANTS done：四种匿名可编辑供热模板、目录/编辑器独立复制快建，以及编辑/预览共用纯色、渐变、上传图片和透明度背景完成。6.1 Terra/Sol实施，主代理审查并退回修正重叠、资源清理及Web图片解码问题。Go全测/vet、Flutter229项/analyze、Windows/Web同源封装和隔离Chrome复制/上传/像素对比/小窗口通过。固定18153及共享桌面入口升级dist/Universal-HMI-ProcessVariants-20261029，源码a787f6a5…；备份20261029-112036-process-variants，PG十一表内容不变，原1账号/4站点/3文档/20审计与5204个GIS文件保留，原页面未刷新。未制作新安装EXE，原生DPI/现场未验；Chrome平台单测加载挂起不计通过。[验证记录](.ai/docs/process-variants-verification.md)。

2026-10-28 INSTALL-FULL-v6完成：按用户旧界面反馈，从当前全部源码重新编译Go与全新Windows/Web输出，交付dist/installers/full-20261028-v6/Universal-HMI-20261028-Full-v6-Setup.exe（0.1.0.6，206936947字节，SHA256 7f289fe4…，内置PG18.6）。来源9ed9f77f…/905文件，Go全测/vet、Flutter215项/analyze、Windows/Web与GIS门禁通过；实际v5→v6覆盖、6270应用/3059PG文件、双入口新路径、十一表不变、旧账号登录与实际Web/GIS字节通过。隔离卸载保留工程并恢复原快捷方式；18153与真实工程未改。目标机旧界面根因尚未复现，原生DPI/现场未验。[证据](.ai/docs/windows-full-rebuild-20261028-v6.md)。

2026-10-28 INSTALL-UPDATE完成：0.1.0.5覆盖安装包dist/installers/update-20261028/Universal-HMI-20261028-PG-Setup.exe（207051797字节，SHA256 19f78600…），内置PG18.6，沿用旧安装身份及工程路径。复用ProcessSurface-v2同源应用，GIS清单通过；0.1.0.4→0.1.0.5隔离安装、6271应用/3059PG文件核验、11表摘要保持、原测试账号登录、Web/GIS字节及卸载保留数据通过，原快捷方式已恢复。仅部署版本/说明变动，无Go/Flutter重编译；固定18153和真实工程未改。原生DPI/现场未验。[证据](.ai/docs/windows-update-20261028.md)。

2026-10-28 PROCESS-SURFACE完成并追加紧凑PC目录：普通页顶部选中项恢复原彩色、无底块仅下划线，内置工艺展示采用钢灰渐变；工艺/站点范围/台账站区/外数据统一248px侧栏。修复切图反复读目录，保留树、搜索与展开状态。Go全测/vet、Flutter215项/analyze、Windows/Web同源构建封装和独立Chrome逐页/12次切图/聚焦键入返回/850×600通过。固定18153 PID71016与桌面双入口升级dist/Universal-HMI-ProcessSurface-20261028-v2，编译来源f71bf432…；备份20261028-171155-process-surface，PG十一表摘要全部一致、1账号/4站点/3文档/12审计保留。原浏览器未刷新，本任务未修改GIS，逐字复用当时已部署MoonRender的5204文件（摘要75d0be52…）。旧15:48版未部署，未出新安装EXE；原生DPI/现场未验。[本批证据](.ai/docs/process-surface-verification.md)。

2026-10-28 GIS月球修正完成：实际Edge/NVIDIA透明OIT使月球不可见，关闭OIT后用户确认可见；后续亮度1.45降到0.90、侧光加大恢复盈凸月阴影，完整Chrome运行页截图确认。环游改为仅亚洲慢、其他区域快（约7.556秒），四轮24次站标生长已验。JS状态机/5项资源测试通过。固定18153和桌面共享MoonRender版本更新，最终GIS摘要18aa7d36…；光照仅静态资源热更新，未再次重启。10表摘要不变、原11条审计保留且新增1条成功登录，1账号/4站点/3文档保留。最终Edge自动化因页面加载检查暂停未完成光照截图；此前真实Edge可见性与最终Chrome光照分别记录，不混称同一验收。未重编译Go/Flutter，未出安装EXE；普通UI由PROCESS-SURFACE继续。[本批证据](.ai/docs/gis-tour-verification.md#月球可见性光照与亚洲慢转修正)。

2026-10-28 RUNTIME-LIGHT完成：普通页浅灰目录/标题/工艺展示、紧凑台账与阅读面板；原MonitorHeader图标造型/标题/时钟/布局保留，仅普通页灰蓝染色并去光晕，GIS仍透明原色。规范在[design.md](.ai/docs/design.md)，明确排除GIS和驾驶舱。Go全测/vet、Flutter212项/analyze、Windows/Web同源封装、Chrome逐页与850×600检查通过。固定18153 PID72440和桌面双入口更新dist/Universal-HMI-RuntimeLight-20261028，源码bd3ba71c1b0e9a9066a307c701111c9ed06e10522ce08616cf1a91ac8632ac89；备份20261028-151844-runtime-light。原1账号/4站点/3文档等10表摘要不变，原7条审计保留，新增2条成功登录；最新GIS文件与上一部署逐字一致。用户原浏览器未刷新。未制作新安装EXE，原生鼠标/DPI/现场未验。[验证记录](.ai/docs/runtime-light-verification.md)。

2026-10-28 GIS-INTRO完成：圆环演示模式立即结束浮窗并拉远进入地球循环；新地图图标为静态展示，地面浮窗持续轮播、再点暂停。保留3.5秒浮窗、1.4秒返回、约9.494秒明慢暗快环游；月球盈凸月/正面远轨道、卫星延长反光及同向不同位置流星/近地缩小完成。JS状态机与5项资源测试、Chrome六轮静态/即时切演示/窄窗/减少动态/编辑态通过。Windows/Web构建通过，但共享构建目录被并行改写，组合包校验拒绝；最终从已部署PerfOptimized作独立GIS覆盖层，仅变更web/gis的15文件，未部署共享构建或改普通页面。固定18153（PID62408）及桌面双入口升级dist/Universal-HMI-GISTour-20261028，GIS摘要9ce00e23…；备份20261028-151531-gis-tour，PG十一表摘要一致、1账号/4站点/3画面保持，原浏览器未刷新。未出新安装EXE、原生/现场未验；旧CI不覆盖本批。[证据](.ai/docs/gis-tour-verification.md)。

2026-10-28 PERF-5000-IMPLEMENT完成：Go授权选择/增量SSE、锁外有界批量周期存储、KingIO主动补全及逐点新鲜度已接入Flutter；工艺目录与标题统一蓝灰，逐页和小窗口截图复核。5000变量/50独立账号各100点，50/50连接成功；5000点每秒全变时SSE合计9.42Mbps，叠加全库1秒存储累计10万样本实际PG行数一致、失败/丢弃0。Go全测/vet、Flutter211项/analyze、Windows/Web同源构建封装及隔离Chrome通过。固定18153（PID75160）和桌面双入口升级dist/Universal-HMI-PerfOptimized-20261028，源码9ce6e1e3…；备份20261028-121817-performance-optimized，PG十一表摘要一致，原1账号/4站点/3文档保留，原浏览器未刷新。后台启动自动审批拒绝，改为工具管理的前台服务已就绪；未出新安装EXE、未测50渲染浏览器/长期负载/真实KingIO/原生DPI，旧CI不覆盖工作树。[验证与截图](.ai/docs/performance-optimized-verification.md)。

2026-10-28 DISCOVERY-SELECT完成：扫描支持 `*` / `?` / 逗号OR，通配条件自动跨页全选，普通关键字提供全选匹配项；翻页保留勾选与编辑，清空后不重选，跳过已添加与类型待确认项并分别计数。共享按钮统一主次、圆角和交互反馈。Go全测/vet、Flutter206项/analyze、Windows/Web同源封装及Chrome609项目录/保存607项通过。固定18153（PID75464）和桌面双入口升级dist/Universal-HMI-DiscoverySelect-20261028，源码e6d9ccb5…；备份20261028-110720-discovery-selection，PG十一表摘要一致，原1账号/4站点/3画面保留，原浏览器未刷新。工具合成星号抬键位置错误单独记录，原生鼠标/真实键盘/DPI与现场未验，本轮未出新安装EXE。[验证记录](.ai/docs/discovery-selection-verification.md)。

2026-10-28 RUNTIME-UI完成：GIS保留原风格，其余运行页统一深蓝导航与浅色内容；工艺目录和数据页站点范围分离，窄屏抽屉/全部页面入口，切站保留当前数据页；修复目录按钮上下文及低窗口台账行被挤掉的问题。Go全测/vet、Flutter201项/analyze、Windows/Web同源构建封装、隔离Chrome大小窗口/菜单/台账详情/GIS检查通过。固定18153（PID59600）和桌面双入口已升级dist/Universal-HMI-RuntimeUI-20261028，源码107fd51b…；备份20261028-101618-runtime-ui，PG十一表数量/摘要一致，保留原1账号/4站点/3画面，未混入演示数据、未刷新原浏览器。本轮未出新安装EXE，原生鼠标/DPI与现场未验。[验证记录](.ai/docs/runtime-ui-verification.md)。

2026-10-28 EQUIPMENT-01首版完成：独立设备台账按站区/小站归档，基础信息、自定义属性、图片及搜索筛选；取消人工在用/维修填报。开发态可选故障/运行两变量及简单公式，Go按需统一判断，运行态只读显示故障/运行/停止、未配置/未知/离线。Go全测/vet、Flutter199项/analyze、Windows/Web同源构建封装、隔离PG重启持久化及Chrome真实绑定/公式保存/状态切换/断网/大小窗口通过。固定18153与桌面双入口已升级dist/Universal-HMI-Equipment-20261028，源码0d3ba318…；备份20261028-093258-equipment，PG十一表数量/摘要保持，原1账号/4站点/3文档保留，无演示数据混入，原浏览器未刷新。Windows原生鼠标/图片文件选择器、真实KingIO及长期容量未验，本轮未出新安装EXE。[验证记录](.ai/docs/equipment-verification.md)。

2026-10-27 GIS-PACKAGE完成：用户“GIS能绑定保存但浮窗数据待绑定、工艺图正常”由打包误用旧site-lod脚本导致。固定源码取件、来源摘要、版本缓存，并更新Web/Windows地图入口。Chrome实际62.30→63.40连续更新/缺失状态/重开保留绑定，Go全测/vet、Flutter193项/analyze、Windows/Web构建及打包回归通过。新包 `dist/installers/gis-fix/Universal-HMI-20261027-PG-GISFix-Setup.exe`，0.1.0.4、204253967字节、SHA256 c5bef7c289d49610314865def9ba21fd3fa6481afdbc134f37735f5d57438823，替代下方初次PG包。实际旧PG包覆盖升级及既有库复用、6265应用/3059PG文件、十一表摘要、卸载保留/快捷方式恢复通过。固定18153（PID74348）与桌面双入口改用 `dist/Universal-HMI-GISFix-20261027`，源码47225f8c36030170d7cc6546eb981df37411e0618b38d5ad40d3341cebab4ec4；备份20261027-173516-password-policy，保留原1账号/4站点/3文档，十一表摘要不变。测试服务及浏览器已关闭，原浏览器未刷新。自动审批拒绝启动原生测试窗口（blocked by policy），不能声称原生浮窗实测通过；目标另一台电脑现场未验。[验证记录](.ai/docs/gis-package-verification.md)。

2026-10-27 PG-INSTALL完成：用户要求重新出包到昨天的无PG电脑并选择懒人模式。交付 `dist/installers/Universal-HMI-20261027-PG-Setup.exe`（204243014字节，SHA256 0b4c9dfc51c77199147595e7aae93ca8f24e1f9a7b2b39ea3570cebc326e6da8）及PG18.6补充ZIP、部署说明、SHA256清单。自动初始化私有PG、备份迁移昨天v2/v3旧工程，两个入口共用后台；原数据不修改，卸载保留PG/密钥/备份。PowerShell5.1真实PG全新/升级/端口冲突/重复/失败重试、v3安装升级、6263应用文件及3059PG文件摘要、原生两入口和卸载通过。应用沿用已验证LoginStyle源码7d3f2694…，部署独立摘要ec2c4446…；没有重新编译或改业务源码。原18153和原桌面入口保持，测试后台停止，目标服务器未现场执行。[完整验证](.ai/docs/windows-lazy-postgresql-verification.md)。

2026-10-27 LOGIN-STYLE完成：登录参考庄河HTML，原生成沿海供热图逐字复用，440px右侧深蓝青边表单、密码显隐与忘记密码提示，窄屏居中/低高度滚动，保留首次建号、验证码、过期、错误与密码清空。Go全测/vet、Flutter193项/analyze、Windows/Web同源封装、独立Chrome实际建号和登录/三尺寸通过。固定18153及桌面两入口已升级dist/Universal-HMI-LoginStyle-20261027，源码7d3f2694f8edf29515db4404819b515fa1e40c2150ba43f4cb91bceffdab9ded；备份20261027-152345-password-policy，PG十一表摘要不变、原账号/4站点/3文档保留。用户原浏览器未刷新；本批原生鼠标/DPI与现场未验。[验证记录](.ai/docs/login-style-verification.md)。

2026-10-27 GIS-PUBLIC完成：用户明确GIS是工程级公共驾驶舱，不归属站点。站点创建只提供工艺图，公共入口保留GIS并说明跨站汇总，后端共享保存用例拒绝非空station的GIS；旧站点GIS仅读取保留原权限，不自动迁移。当前唯一GIS原本公共无需改数据。Go全测/vet、Flutter193项/analyze、Windows/Web构建封装、隔离HTTP与Chrome实际创建/回读通过；固定18153（PID26200，dist/Universal-HMI-GISPublic-20261027）及桌面双入口已升级。源码0d6629cff9a1cf4106f5914a2dd176587bac831726b7715542a25d3a2dcb7216，备份20261027-150824-password-policy，PG十一表数量/摘要保持、1账号/4站点/3文档不变。原用户浏览器未刷新；本批原生交互和现场未验。[验证记录](.ai/docs/gis-public-verification.md)。

2026-10-27 EXTERNAL-DATA首批完成：按用户选择由Go直接查询外部SQL Server，独立于内部站点，工程师配置数据源和多个日报/明细/趋势画面，业务账号按external_screen_ids单独授权。参考现场资料SQL2019/172.16.1.7/KIOHistory与KS每60秒入库、HTML定义驱动日报；首批固定Station/Point/StationSample结构，未连接现场。Go全测/vet、Flutter192项/analyze及最终19+5项、真实隔离SQL2019的505条数据/只读账号/精度时区分页、Chrome和Windows/Web构建封装通过。固定18153（PID41012，dist/Universal-HMI-ExternalData-20261027）与桌面双入口已升级，源码f679bb1fb5208051e15ef9c85f3c7f817ed96fdde90b1f9eb7ebe230fc76027a。备份20261027-144407-password-policy，PG十一表数量/摘要保持，1账号/4站点/3画面不变，原用户浏览器未刷新。连接密钥external-data/connection.key随工程备份；测试库未带入原工程，隔离服务/容器已停止。[验证与未验边界](.ai/docs/external-data-verification.md)。

2026-10-27 SECURITY-RAIL完成：权限配置移至开发工作台最左活动栏底部，顶部重复入口删除，管理员可见性及原弹窗保持。Go全测/vet、Flutter187项/analyze、Windows/Web同源构建封装及隔离Chrome交互通过。固定18153（PID51580，dist/Universal-HMI-SecurityRail-20261027）及桌面双入口已升级，源码c9423598ba26b786e02fca918de831c3d256ac28363106e516517f351f7f891d。备份20261027-141527-password-policy，PG十一表数量/摘要一致，原1个账号、3份文档保留，用户浏览器未刷新。[验证记录](.ai/docs/security-rail-verification.md)。

2026-10-27 TEMPLATE-PICKER完成：添加画面先选工艺图/GIS，工艺图下独立分类、搜索列表、选中预览及名称，模板目录支持继续扩展。保留手填名称、公共同步布局/本站绑定和内置独立文档语义，修复窄屏侧栏卸载后创建不能自动打开的问题。Go全测/vet、Flutter187项/analyze与最终17项回归、Windows/Web同源构建封装及隔离Chrome通过。固定18153（PID71612，dist/Universal-HMI-Templates-20261027）已升级，源码c5cfab7e62e7c88c6d88820b80b4222775c35d3df70522d0e49fc4700fdedb26。备份20261027-140704-password-policy，PG十一表数量/摘要一致，保留1个账号及3份文档。桌面双入口指向新包，用户浏览器未刷新。[验证记录](.ai/docs/template-picker-verification.md)。

2026-10-27 KingIO依据已按用户授权咨询“解答疑问”并独立核对旧Edge项目：20260908真实KingIO test源记录92消息，选定随机点81样本、恒定点1样本、改值恢复点3样本，支持变化增量。旧客户端OnConnect订阅后主动Query_AllKIOTags取全量，缺初值另补查；不是MQTT订阅自动保证全量。当前Universal HMI未自动发该查询。周期全量/全静态心跳/质量单独变化保证仍未知；静态点首次源时间比接收早157秒，不能简单按源时间判失效。证据并入[容量分析追加](.ai/docs/performance-5000-20261027.md#kingio变化上报证据追加)。本次只读咨询，不连现场、不改产品。

2026-10-27 PERF-5000分析完成，未改产品代码：用户明确5000总变量、MQTT1秒、50人，各运行页仅50–100变量，并说明KingIO首次全量后续变化的模式理解。当前SSE仍每500ms发权限范围全量且上限32；实测50连接32成功/18拒绝，32连接689Mbps。5000值每秒全变的采集边界短测95万样本零丢弃；全库1秒历史策略PG超时、0提交，并阻塞实时。应按画面订阅+增量合并、独立处理元数据和健康状态，并批量锁外存储；纯变化上报时当前按源时间判陈旧有语义风险。实际变化率/心跳需现场确认，原18153保持。[分析](.ai/docs/performance-5000-20261027.md)。

2026-10-27 UX-WORKFLOW完成并升级固定18153（PID55640，dist/Universal-HMI-UX-20261027）：独立建空站→站下从公共工艺图添加，公共布局同步、多站分别绑定；统一资源树、集中变量绑定、保存并关闭、独立折叠、真实空态和公共布局版本刷新，清理旧全局目标编辑器/引用即副本及重复入口。Go全测/vet、实际PG集成、Flutter183项/analyze及最终5项回归、Windows/Web同源构建封装、隔离Chrome完整创建/绑定/布局同步通过。源码54e7b9a7c8d6760386c3158bfa008999555c7f23a6ffbc2d751a2c66974248a2。升级前备份20261027-132552-password-policy（沿用备份脚本命名），PG十一表数量与逻辑摘要均保持；此时已有1个用户、3份文档，账号和原数据未修改。原独立图不自动关联，用户浏览器未刷新。桌面双入口读取同一project.json指向新版。[本批验证](.ai/docs/ux-workflow-verification.md)。

2026-10-27 AUTH-PASSWORD完成：用户要求本机可用admin，随后明确公网7位即可。规则为显式本机5–128、公网默认7–128，创建/重设/本人改密统一，UI由password_min_length显示。Go全测/vet（实际PG）、Flutter177项/analyze及Windows/Web同源构建封装通过。固定18153与桌面共享工程已更新至dist/Universal-HMI-PG-20261027-v2（PID48812），源码60d860079ea165320aefa137a49bc2814b8249e04d85747c65f30a38a9b20705；实际Chrome确认首次设置页显示5–128。停服备份20261027-121224-password-policy，PG十一表数量和逻辑摘要均保持，账号仍为0，首次管理员由用户自行设置。[部署证据](.ai/docs/evidence/20261027-postgres/password-policy.json)。以下PG-01记录为初次部署历史。

2026-10-27 PG-01完成：固定18153已迁移至本机PostgreSQL18.2专用universal_hmi库（PID10380，程序dist/Universal-HMI-PG-20261027，原工程data不变）。自定义角色可新增/编辑、配置功能权限并批量分配，修改后重算成员授权并撤销会话；开发态入口“权限配置→角色管理”。桌面新增运行态/开发态两个独立图标，均复用该后端，关闭窗口不停止共享服务。最终备份20261027-114719-before-pg，3份工程文档逐字相同、4个站点身份保留、原SQLite逻辑摘要不变；无测试账号混入。首次管理员待用户自行设置。Go全测/vet及实际PG集成、Flutter175项/analyze、Windows/Web同源构建封装、Chrome角色交互和两个原生初始页通过；原生登录后及真实TLS/KP/OT未验。[验证记录](.ai/docs/postgres-verification.md)。后台启动自动审批拒绝，当前由工具管理的前台进程提供服务；图标复用路径已验证，服务停止后的自动拉起尚未实测。

2026-10-27 最新业务定位：仅供领导层使用，不设置普通员工角色或工作流；领导岗位使用自定义角色，功能能力与岗位名称分离。工程师开发维护及管理员配置仍按此前确认保留。没有默认创建任何领导/员工账号，组织职级由管理员确认后配置。

2026-10-27 SECURITY-01第一版已实施并部署固定18153（PID63136，server-security.exe，web-security-final-20261027，沿用原data）。多用户/Argon2id、TOTP/恢复码、会话撤销、稳定站点范围、工程师开发/独立管理员入口、实时/历史/画面/菜单/文件任务/受控写入授权及正式KP统一身份已实现。工程师+全部站点可开发，管理员本身不可；初始owner无设备下设权。Go全测/vet、Flutter171项/analyze、最终健康4项回归、Windows/Web release、独立Chrome建号/角色范围/MFA及后端自动端口通过；原3份JSON与SQLite逻辑摘要不变、完整性ok，备份20261027-110326-security。首次账号由用户自行设置，未复制测试凭据或刷新原浏览器。[验证](.ai/docs/security-verification.md)。本轮未打新安装包，原生人工、实际TLS/KP/OT仍未验；安全增强归SECURITY-02，真实部署归AUTH-DEPLOY。旧CI不覆盖工作树。

2026-10-27 最新确认并开始SECURITY-01实施：用户明确选择“工程师可以开发，其他用户不能开发”，随后要求“开始实施吧”。恢复工程师角色与后端开发能力检查，普通管理员不自动获得开发权；此决定替代下一条的临时禁用全部开发权方案。保持18153及原数据，后端identity/authorization、业务权限覆盖、Flutter用户管理与界面能力、验证部署正在实施；未完成项不得据设计宣称已完成。

2026-10-27 用户确认安全方案并收紧开发边界：所有用户只有Web/用户端使用权，开发权不授予任何用户（含管理员）。已删除目标设计中的工程师角色，开发编辑/发布能力不进入用户可授权集合，用户服务须拒绝开发路由、API和MCP工具；开发仅属独立受控环境/发布流程，用户管理界面与开发工作台分开。agent.md与架构母本、SECURITY-01同步；本轮仅修订设计，运行中的18153及原工程未改，不能宣称开发接口隔离已实现。

2026-10-27 用户要求固定18153并保留原工程，已完成新版升级（PID43952，server-navigation.exe，web-navigation-20261027，沿用.local/gis-editor-preview/data）。备份.local/gis-binding-preview/backups/20261027-093038-navigation，3份JSON摘要及SQLite逻辑内容一致、integrity ok；未刷新用户原浏览器。18153现在已更新，取代上条“拦截未更新”的历史状态。[证据](.ai/docs/evidence/20261027-page-navigation/deployment-18153.json)。后续固定此评审入口，其他端口仅隔离测试。用户提出公网/内网安全与用户权限；已审查现有单账号/KP全工程权限、全量实时快照及文件任务边界，将统一身份、动作+资源范围、MFA、审计和部署目标写入架构母本，SECURITY-01 open待实施；本轮未扩大网络监听或创建真实凭据。

2026-10-27 通用页面导航与GIS跳转完成：独立菜单树支持跨站分组/排序，组名展开并打开首个有效画面，箭头仅折叠；GIS站标选择稳定工艺画面目标，拖动保存保留目标。Go全测/vet、Flutter168项及最终16项/analyze、Windows/Web release和真实Chrome点击/保存/小窗口验证通过。独立最终预览18157；18153替换被自动审批拦截，原服务和用户页面保持。未重打安装包，本次原生交互未验；[验证记录](.ai/docs/page-navigation-verification.md)。PROJECT-01原open范围及PROCESS-01评审继续，旧CI不覆盖工作树。

2026-10-26 数据源扫描添加完成：选择来源/目标站、关键字过滤、类型识别/修改、每页200项批量保存和已添加标记；KingIO首次全量包在零点位时即进入目录。Go全测/vet、Flutter166项及最终4项回归/analyze、Windows/Web release通过；独立18155真实MQTT首次1包250项、过滤10项保存与重复检查、小窗口实际鼠标通过。18153预览更新；本轮未重打安装包，真实KingIO现场未验。[验证记录](.ai/docs/point-discovery-verification.md)。PROJECT-01原未完成边界不变，旧CI不覆盖本轮工作树。

2026-10-26 桌面端口回退完成：18080 被其他程序占用时自动选择可用回环端口，API/GIS 共用实际地址。Go test/vet、Flutter analyze/162 项、Windows/Web release、v2→v3 覆盖安装、6256 文件核验、占用时 26810 上原生 GIS/工艺图、空闲时 18080、正常退出及卸载保留数据均通过。新安装包 dist/installers/Universal-HMI-MQTT-GIS-20261026-v3-Setup.exe；沿用 v2 数据目录，WebView2 仍独立安装，现场 MQTT 未验。详见[本批验证](.ai/docs/desktop-port-fallback-20261026.md)。

2026-10-26 变量语义核验与 AI 约束补齐：同一共享工程内跨站虚拟点引用同一输入、各站独立周期落库已由新增 SQLite 回归确认；坏质量保留异常记录、改公式不改旧历史、拒绝跨站误存也通过。Go 1.24.7 全测/vet通过；agent.md 保留产品母本，architecture.md 为唯一变量技术合同，AGENTS/workflow增加 Fork 与语义变更必读入口。见[核验记录](.ai/docs/variable-semantics-verification.md)。仅文档/测试，未改运行代码或用户配置；多工程与反查仍未实现，未做 UI/现场验收。

2026-10-26 Windows 安装包完成：冻结已验v2封装为 dist/installers/Universal-HMI-MQTT-GIS-20261026-v2-Setup.exe（约156MiB）；三个桌面/开始菜单入口、卸载保留数据；按用户要求WebView2独立安装。隔离实际安装6256文件核验、GIS/工艺/开发三入口及退出、卸载和数据保留均通过。未签名测试版，现场MQTT未验。详见[安装包验证](.ai/docs/mqtt-trial-20261026.md)。

2026-10-26 页签菜单归属修复：公共/站点页保留各自运行导航，GIS与工艺文档直接显示自身工具栏；切回或关闭最后文档恢复原工作区功能，GIS预览状态按文档保留。目录加载中不再出现临时默认GIS入口。Flutter analyze/160项、Web/Windows release通过；实际Chrome验证公共/单站/工艺/GIS菜单与状态恢复，18153已更新。证据见[页签菜单验证](.ai/docs/screen-workspace-verification.md)。

2026-10-26 GIS上方弹窗统一修复：外部弹窗/菜单覆盖时按当前ModalRoute暂停底层地图输入，嵌套关闭后正确恢复，预览自己的地图仍可交互。实际Chrome验证添加画面输入/下拉/取消、未保存关闭确认、变量搜索/逐层取消、项目菜单、工作区选择、预览关闭及640×300滚动。Flutter analyze/158项、Web/Windows release通过；18153已更新，用户已保存画面摘要不变。详见[弹窗检查](.ai/docs/screen-workspace-verification.md)。

2026-10-26 原生 GIS 临时包 v2 完成：Windows EXE 内嵌离线GIS与工艺图，支持客户GIS/客户工艺/开发配置三个启动入口，独立测试工程首次加载无绑定示例。Go test/vet、Flutter analyze/157项完整测试及最终10项回归、Windows/Web release通过；实际原生GIS浮窗62.30°C、工艺图61.2→62.3更新、启动首页保留和退出脚本清理通过。现场MQTT未验；直接EXE后台残留仍归UX-02。产物dist/Universal-HMI-MQTT-GIS-Trial-20261026-v2.zip，详见[临时包验证](.ai/docs/mqtt-trial-20261026.md)。

2026-10-26 GIS顶部菜单点击修复：真实浏览器复现透明导航点击命中iframe，增加仅覆盖导航的Web透明DOM隔离层；宽屏/紧凑布局四菜单鼠标切换与地图拖动通过（未启用semantics）。Flutter analyze/155项、Web/Windows release通过，18153静态资源已更新，数据未迁移。证据见[导航点击验证](.ai/docs/screen-workspace-verification.md)。

2026-10-26 MQTT 临时测试包：按用户要求从当前工作树构建 Windows x64 EXE + Go + 同包 Web/GIS，源码摘要4b8294f0…。Go test/vet、Flutter analyze/155项、两端release及原生启动/接口/同包Web字节验证通过。实测窗口exit0后后台残留；随包精确路径停止脚本已验证，长期修复归UX-02。Mosquitto缺失，真实MQTT集成跳过，现场站点/绑定由用户测试。产物dist/Universal-HMI-MQTT-Trial-20261026及同名ZIP，详情见[临时包验证](.ai/docs/mqtt-trial-20261026.md)。

2026-10-26 GIS浮窗绑定完成：五项指标可从共享变量库按稳定ID跨站选择、搜索与解除；随GIS独立草稿/revision保存，拖动保留绑定。浮窗经现有SSE展示真实数值/单位及缺失、坏质量、陈旧、离线状态。Go全测/vet、Flutter analyze/155项/Web/Windows release通过；真实Chrome选择/保存/拖动/重开/连续更新及断开服务显示离线通过。18153更新为新后端/Web（PID8948），原已保存画面摘要未变，用户浏览器未刷新；刷新前先保存会话草稿。证据见[GIS绑定验证](.ai/docs/screen-workspace-verification.md)。独立多工程/变量反查不在本批。

2026-10-26 PROCESS-01 编辑态多画面页签完成：按画面ID保留工艺/GIS独立草稿，重复打开激活原页签；同站多图、新建/导入/引用/副本不替换已开画面，关闭脏页签需产品内确认。Flutter完整153项、最终15项回归/analyze及Web/Windows release通过（源码1ddf406a…）；实际Chrome三页签、改名未保存切图恢复和撤销通过，已保存的两张示例图revision未变。内置18153开发预览保留工艺/GIS两页签。证据见[多页签验证](.ai/docs/screen-workspace-verification.md)。草稿仅会话内保留，未增加刷新恢复能力。

2026-10-26 GIS重播与导航：海面常开、移除全屏及海面开关，右下角淡色纯图标重播；从当前相机平滑拉远2.4秒再接6秒飞入，连续点击不硬切。客户GIS全窗口地图+透明导航，切回工艺恢复背景。Flutter analyze/6项相关回归、Web/Windows release通过（cb3e5852…），真实Chrome拖动后的重播首帧坐标/高度不变、最终归位、重复重播与菜单点击通过。证据见screen-workspace-verification追加；原生GIS仍未实现。

2026-10-26 PROCESS-01 展示净化与GIS编辑完成：客户GIS铺满顶部76px以下区域，隐藏来源浮条；工艺页仅站区导航和纯画布。开发端只提供只读预览，GIS新增/经纬度/拖动/移除留在编辑器并按独立文档revision显式保存。Go全测/vet、Flutter完整150项及最终12项回归/analyze、Web/Windows release通过（源码52abb249…）；18153隔离预览实际Chrome新增、拖动、保存、预览只读、重开通过，临时测试站点已清理。内置预览已更新18153。详见[验证追加](.ai/docs/screen-workspace-verification.md)。真实站址/点表及原生GIS仍待后续，本批不由旧CI覆盖。

2026-10-26 PROCESS-01 本批完成：原浅色整套工作台归开发端，活动栏只切换相邻面板，具体资源再打开中央内容；客户运行页无开发入口，工艺菜单为站点→画面。GIS可手动添加公共/站点实例，每次进入重播6秒飞入，嵌入页禁用拖动站址。运行内存值改SSE。Go全测/vet、Flutter149项及最终18项回归/analyze、Web/Windows release通过；独立18152实际Chrome与内置预览通过，详见[本批验证](.ai/docs/screen-workspace-verification.md)。点表/真实站址、原生GIS及用户评审继续跟踪，旧CI不覆盖本批。


2026-10-26 导航高度反馈已调整：桌面112→76px、窄屏164→112px、图标74→48px；时钟单行自适配，保留选中光效。Flutter145项/analyze及Web/Windows release通过，18151内置预览已更新，证据并入供热监视验证。

2026-10-26 GIS菜单接入：Flutter Web首页GIS（view=gis/page11）与工艺画面共用导航，platform/gis_view条件适配同源gis/map.html；ci/stage_gis.py随Web构建部署本地影像，不依赖18149。首次6秒/切回直达/离开销毁iframe；白色浮窗去关闭按钮和点击固定，移出站标与卡片180ms自动收起。18151浏览器菜单切换、同源地图、6站与自动收起通过，analyze/Web构建和5项监视回归通过；原生只提供浏览器提示，KP现场与真实站点/测点仍未接入。详见examples/gis-flight/verification.json。

2026-10-26 导航外观：工艺页顶部和侧栏使用六张内置image_gen透明图标；每功能一图，Flutter代码控制选中/未选中及悬停，配合静态星点、发光底线与侧栏玻璃渐变。三尺寸实际Chrome、搜索切站和悬停通过。代码在monitor_chrome.dart，素材及提示词在app/assets/monitor；详细构建结果见[供热监视验证](.ai/docs/heating-monitor-verification.md)。仍归PROCESS-01，点位接入等待用户点表。

2026-10-26 GIS浮窗：白色工业信息面板、冰蓝标题区/同款站标/细蓝边框、深蓝标题，一次/二次侧供回水双列分组，压力独立；保留数据待绑定状态与拖动位置。真实Chrome悬浮显示、360×420容器内边界/滚动检查通过，控制台无错误。

2026-10-26 供热工艺监视页：沿用现有开发页与ProcessScene，新增深蓝只读站点菜单、搜索/切站和1574×674可编辑参考模板（94元素、27未绑定值）。写实换热器/泵/流量计和最新电子温度表、压力变送器、泄压阀、金属拼装水箱进入素材库；管线在法兰图层上方接入孔中心。Flutter analyze/144测试、Python3项、Windows/Web release和实际Chrome新建/保存/刷新重开/切站/三尺寸通过。仅18151隔离预览，未改18139/11005/18149；点位表待用户提供，GIS未集成，用户视觉验收未完成。追踪PROCESS-01，证据见[供热监视验证](.ai/docs/heating-monitor-verification.md)。基点CI不覆盖本批。

2026-10-26 GIS站区与开屏：用户透明PNG替换原站区图标；自动6秒飞入，删除地名标题/中心庄河标记/底部飞行面板；最后减速段5.4秒起90ms错峰560ms生长回弹，仅入场一次。stations.json按稳定ID配置示意坐标，悬浮浮窗/点击固定/本机拖动位置编辑；真实站址与实时数据仍待接入。Chrome约6.00秒落地、6站顺序动画/悬浮/固定/HTTP验证通过，无控制台错误；仅18149独立展示。

2026-10-26 庄河动态海面：GIS独立近景材质，SCL海域遮罩约90KB+法线约437KB；随视角高光/流动细波纹/缓涌，抵达后持续呈现动态壁纸感，85→35km渐入、30Hz封顶，开关/远景/减少动态停止更新。仅展示，非实时海况；源和边界在examples/gis-flight，18139/11005未改。证据见演示verification.json，现场机仍待验。

2026-10-26 GIS轻量画质迭代：新增NASA东北亚2048纹理（不到1 MB传输，约16 MiB解码），弥补全球至辽东清晰度断档；非对称对数高度曲线提前抵达区域，转向与缩放同步落定。原始大图仅构建缓存，来源/摘要/调色入region-source.json。无云层；生产目标机仍待验。

2026-10-26 GIS过渡修正：保留连续NASA底图，旋转视野进入覆盖范围再显现区域瓦片，运行时3层/文字10Hz。暖缓存1367×770两次RAF P95约16.8ms，不作目标机保证。用户否决穿云贴图，已从源码/运行页/资源撤除；后续先参考游戏与Earth Studio镜头方案，不再自行加云。

更新：2026-10-26 GIS视觉迭代。按用户要求地球改NASA Blue Marble 2004-08真实合成影像、侧向明暗/大气边缘、本地静态装饰星空；保留庄河细节/大连低清/其他地面模糊。默认18→8秒，6/8/12可选，五次缓动与飞行4%–90%期间持续逆时针90°转向。实际Chrome默认8秒在9秒观测完成，heading90且北点投影x负/y约0，图层零失败/无外网HTTP，旋转仅地图、UI正向。说明/来源校验/许可及验证同步在examples/gis-flight，18149静态文件已更新，无需重启；生产接入边界不变。

更新：2026-10-26 GIS 技术演示完成，生产接入待验。新增 `examples/gis-flight/` 独立 Cesium 展示组件，固定 2025-09-29 Sentinel-2 六景，庄河 10 米原始细节/大连约120米/全球模糊三级图层，本地 4,797 张 WebP 瓦片，地球到庄河飞行、暂停/重播/进度与三种嵌入尺寸通过真实 Chrome 验证。独立回环 18149 持续运行；本轮未改 HMI18139、KP11005 或业务数据。资源/Cesium/字体无外网运行请求，Go静态服务vet/build及实际HTTP边界、JS/Python语法通过；未实际断用户网络。源码、影像构建、许可与可复现记录见 [演示说明](examples/gis-flight/README.md) 和 [验证](examples/gis-flight/verification.json)。原始影像/构建/缓存/演示包归 `.local/gis-flight-demo/`；不进源码。10米非建筑级高清，矩形范围非行政边界，真实站点、KP/Flutter集成、目标机性能和生产验收待后续；当前基点f552d81的CI成功不覆盖工作树。GIS后续只由GIS-01看板追踪。

更新：2026-10-13 KP登录加载性能。用户确认继续用此前接通账号；独立Chrome真实KP认证请求约48ms，登录页DCL0.913–1.371秒，两次现有脚本blank→业务iframe均额外等待约2.03秒。server/kp.go构建资源改private/no-cache，其余入口/会话/业务仍no-store；Go全量test/vet/Windowsbuild、18项KP脚本回归通过。隔离与实际18139会话/权限/304通过，18139已更新为cache二进制，当前PID70860，重复启动复用，原三张画面摘要未变；真实KP容器已恢复显示既有工作区。浏览器两轮资源传输25.45MB→16.44MB，主程序与wasm复用，完整中文字体仍重传，不声称全部资源命中或端到端加速倍数。已新增共用自定义脚本调用示例，在KS_HELP目录交付快速启动调用.js/配置说明；实际KP打开事件仍由用户应用，未改KP工程/厂商代码。原型脚本24ms发起业务URL仅证明调用，不代表实际页面全加载。真实KPLogOff、正式身份与真实多IP仍未验，见 [.ai/docs/kp-performance-verification.md](.ai/docs/kp-performance-verification.md)。本批工作树修改，基点CI全量38031925059/生命周期38031925060成功不覆盖本批。

更新：2026-10-13 18139已启用KP本机联调。用户确认bootstrap/kp入口404并更正当前KP用户名后，按可编辑operator显式白名单配置实际KP来源11005；私有配置/幂等Start-KP.ps1/Verify-KP.ps1在.local/kp-local-18139，配置ACL限制当前账户与管理员，不进入Git。复用前轮已通过的binary/Web，加public-origin/kp-config/kp-local-trial，保留原数据，PID68856持续隐藏后台运行。隔离18145及实际18139的bootstrap/redeem/me/读取/poll/测试会话退出与模拟closed200，匿名401、未知用户/来源403；独立Chrome实际工作区显示当前用户、票据清除，无error/warn，一项弃用issue。三张用户画面摘要未变；测试页/心跳/18145已清理。现用KS_HELP三段脚本协议已吻合，无需改；用户需在实际KP重新登录。当前是用户名白名单的回环试验，不是正式可信身份/多IP验收，真实KP LogOff未运行。见 [.ai/docs/kp-local-trial-verification.md](.ai/docs/kp-local-trial-verification.md)；旧kp_enabled=false记录只代表启用前状态。

更新：2026-10-13 KP iframe 拒绝连接修复。18139服务实际正常；独立 Chrome 跨端口 parent18147→blank18139 复现用户相同错误画面，控制台确认本机空白页 frame-ancestors self 拦截。同主机不同端口仍跨来源，本机纯空白页改为不带嵌入限制，正式KP来源白名单、Host/TLS及业务权限保持。Go全量test/vet/Windows服务build passed；更新18139独立隐藏后台进程 PID68556，真实跨端口 frame 从 chrome-error 变为 blank.html，控制台无拦截、三张原画面摘要未变。当前未启用kp-config，bootstrap404；实际KP来源11005与样例18146不同，须按合同准备配置/身份授权。未检查用户Chrome或执行真实KP登录/LogOff，未改Flutter/用户页。证据见 [.ai/docs/kp-blank-verification.md](.ai/docs/kp-blank-verification.md)，本轮仍为工作树修改；旧HTTP200不当作嵌入成功证据。

更新：2026-10-12 KP 容器空白地址修复（基点 f552d81，工作树本批修改）。Go 内置 `/blank.html`，本机/KP 入口共用，GET/HEAD 200、no-store、无脚本/业务，KP 退出或失效凭据可直接加载且保留 Host/HTTPS/frame-ancestors。定时脚本六处、登录/退出示例各一处改为 `base + "/blank.html"`；附件六处已生成保留原 18139 base 的修正版。Go 全量 test/vet 与 Windows 服务 build、17 项脚本模拟和附件语法 passed；18139 已以独立隐藏后台进程 PID43368 更新，blank GET/HEAD、首页200和登录检查正常，三张用户画面 SHA256 未变。未改 Flutter、未启用 KP 配置/真实凭据，真实 KP 容器仍待用户重试。证据与文件路径见 [.ai/docs/kp-blank-verification.md](.ai/docs/kp-blank-verification.md)；基点两项 CI success，不冒称本次未提交修改远端已验。

更新：2026-10-10 KP 联动接口已实施，基点 b56ae1f、沿用 codex/process-canvas / PR14。新增 Go internal/kpbridge 单一会话权威、可信 verifier 端口、显式 subject/角色授权、一次性票据及 KP/Web 分通道；Flutter 每窗口 sessionStorage、退出提交前退役业务/弹窗/旧请求，KP 壳三段脚本和正式/本机配置在 examples/kp-bridge。多用户、同账号多IP和共享NAT按登录实例隔离，IP不是身份；重启/断网/迟到响应/过期退出意图均覆盖。Go全量test/vet（150顶层测试）、Flutter analyze/140项/75文件格式、17项脚本、Windows/Web release+verify-only passed，最终源码919830a4…。独立Chrome同账号两窗口退出/刷新、false→true、viewer读取200/写入403通过；宿主焦点下关闭通知的TypeError已定位自动抢焦点并做红绿回归，最终复测无pageerror，有一条service-worker启动超时警告。18139未重启/用户页未刷新，原画面数据目录未写；测试服务仅18145/18146。默认KP关闭，未部署客户凭据/设备；本机race因CGO/编译器未运行，最终CI另核。真实KP凭据/verifier、LogOff跨终端范围、实际多机/嵌入存储/证书仍待操作方，当前角色覆盖一个共享工程、非逐用户数据隔离。合同与文件划分/证据见 [.ai/docs/kp-bridge.md](.ai/docs/kp-bridge.md)、[.ai/docs/kp-bridge-verification.md](.ai/docs/kp-bridge-verification.md)，接口工作KP-01完成，部署边界归AUTH-DEPLOY。

更新：2026-10-10 保存报错诊断。`server/process.go` 区分未知字段/数值类型/JSON语法与截断/8MiB/尾随内容/身份错误，仍保留严格解码与原失败状态。新增十一类 HTTP 拒绝并验证原文件不变，以及所有管道选项 roundtrip。独立18143实际绘制/设置圆角、弯头、箭头总数6、动画/反向，保存200/v3并刷新测试页重开通过。Go全量test/vet、Flutter analyze/131项、Windows/Web release+verify-only通过，源码摘要d9d14a4a…。18139仅后端更新，原三张用户图未改写、用户页未刷新。原截图失败请求尚未取得，未确定具体原因，已请用户在原报错页重试取得新提示；不能声明原故障已定位或全部解决。b210b47 CI38023645560最终success（macOS DMG打包曾hdiutil Resource busy，重跑失败job后通过）；生命周期38023645551success。PR14新head独立核查。

更新：2026-10-10 素材接管修复。截图中的板式换热器空隙源于 SVG 等比居中而端口按元素外框计算，旋转也未同步。新增纯 `symbol_geometry.dart` 和离线生成的 462 项 viewBox 尺寸常量，绘制/吸附/管道解析统一；四个自绘设备使用实际绘图接触坐标，未审阅外部设备仍只提供内容框边点。稳定端口名与后端文档不变，已有连接随缩放/旋转校正，自由管道不猜测绑定。Go test/vet、Flutter analyze/131项/68文件只读格式、Python3项、Windows/Web release+verify-only passed，源码 `c8ecdd90…`，构建基线10af848。四设备×四方向像素断口、真实 Chrome 右边拖宽/接新管/撤销和640×360嵌入通过；18139仅更新Web，三张用户图摘要未变，用户页未刷新。证据 `.ai/docs/evidence/20261010-process-symbol-ports/verification.json`。此前10af848 CI38022212602及生命周期38022212630 success，本修复新head以PR14为准。

更新：2026-10-10 管道/箭头批次。`codex/process-canvas` 增加端点/中部拼接、草稿按点击撤销/重做、直角单轴投影与方向迟滞、自由角及 5/10/15/30/45/90° 步长；伪 3D 圆管、独立圆角/半径/弯头设置；智能参考线/吸附及 Shift 拖动约束；箭头间距/整条总数（旧 segments 归一）、动画、反向朝向与运动、最多八项 AND/OR 显示/运动条件。模板导出及所有实例化清空实际绑定，实例才选择该站变量。纯几何/展示模块在 features/process，Go process 唯一校验/原子保存，不触发设备控制。Go 全量 test/vet、Flutter analyze/全量128项/65文件只读格式、Windows/Web release+verify-only passed，工作树源码摘要 `180a2896…`、Git 基线 f6cbc01。独立真实 Chrome 验证水平防偏移/绘制撤销/保存重读、中心参考线、管道分支、模板占位到实例绑定、整条三个反向箭头和实时条件；同一640×360嵌入弹窗样本20→5隐藏箭头，文档revision=2不变，控制台无错误/警告。证据见 [.ai/docs/process-screens.md](.ai/docs/process-screens.md)。18139 已换本批 Go/Web，原三张画面字节不变，用户未保存页未刷新；f6cbc01基线CI38016543298/生命周期38016543300全绿，新提交CI独立核查。原生人工/DPI/race/现场仍未验。

更新：2026-10-10 编辑交互修复。`codex/process-canvas` 已修复右侧文字/数值草稿点击画布不提交：操作前同步提交、回写原元素 ID、去重提交。矩形/椭圆及文字/数据/设备支持左键拖出任意范围，绘制预览松开才提交；选中元素四边整段及四角均可缩放，另一侧固定、最小尺寸/画布边界保留、单步撤销。新增 19 项回归，Flutter 全量 115 项/analyze/59 文件只读格式、Go test/vet、Windows/Web release+verify-only passed，工作树源码摘要 `aa57175b…`。独立真实 Chrome 文字点击另一元素立即生效、拖出三种范围、四边非中点拖动逐次保存重读与撤销重做 passed，控制台无错误/警告；证据见 [.ai/docs/process-screens.md](.ai/docs/process-screens.md)。用户 18139 提供新 Web，未自动刷新其未保存页面；当前 Go 支持 process_screens，Windows 构建目录旧 Go 已替换。基线 a53ead27 的完整 CI 37910510085/生命周期 37910510073 passed，新提交远端验收另核；原生人工/DPI/现场仍未验。

更新：2026-10-09 参考图/嵌入组件批次。PR #14 的 `codex/process-canvas` 已加入明确「新建模板」（空白/三换热器供热站）、1280×660 可编辑蓝图（120 元素、33 个默认未绑定变量位置）和四个自绘设备 SVG。统一 ProcessScene 绘制、ProcessViewport 等比适配、只读 ProcessDiagram；总览可嵌入，开发页四种容器预览，缩放/拖动/正常字号变量表，宿主提供实时快照、不另开轮询。label/单位/小数保存及新接管点向后兼容。Go test/vet、Flutter analyze/全量 96 项、最终专项 6 项、Python 扩展 8 项/素材 2 项、Windows/Web release 与 verify-only passed，最终工作树源码摘要 e6f26720…。真实 Chrome 四尺寸、总览宽/窄/低高、预览打开时 65.43→77.78°C 更新、两站文档与 revision 查看后不变已验；证据和文件组织评价见 [.ai/docs/process-screens.md](.ai/docs/process-screens.md)。原 head 6c54216 的 CI37902463317 因 MCP 数量旧断言 32/实际40失败，已校准总数并检查新增八工具；新 head 远端检查以 PR 为准。未验原生窗口/DPI/现场设备；当前全站合计64画面/单图8MiB、图片嵌入副本、独立全局用户模板版本库尚未实现。

更新：2026-10-09。本轮接手已同步 main `b8d3b77`，对应 CI37034415067成功；在 `codex/process-canvas` 实施工艺画面。用户授权直接嵌入免费工艺素材，并追加独立「开发页」用于先拖摆示例、由 AI 完善模板。已加入 458 个固定提交 FUXA 静态 SVG、设备/直角管道、图片/文字/实时变量、位置/精度/显示单位、保存冲突与 JSON 模板导入导出；开发页编辑、工艺画面查看。素材来源与边界见 `.ai/docs/process-screens.md`、`app/assets/process/README.md`。已追加工作区共享「我的素材」：上传透明 PNG/JPEG，名称/分类、搜索/拖放，原字节保留，各站画面嵌入独立副本。免费实物来源筛选见 `.ai/docs/process-assets.md`。Go 全量 test/vet、Flutter 全量 88 + 新素材 2 项、analyze、素材完整性 2 项、本地 Windows/Web release 与 verify-only 已通过（最终源码摘要 d4aa5386…，交互批次 ea3e8312…）。实际 Chrome 文件选择上传、A 点击放置/B 拖入、保存字节/精度/单位独立已通过，证据见工艺画面说明；新 head CI 待远端结果，不沿用旧批次验收数字。

更新：2026-10-02。用户追加三平台实际安装包、广泛测试、截图，以及在 dot 电脑展示安装后的 Linux 应用和浏览器 Web。当前从 main `656011b` 开始实现；macOS 目标 Intel/Apple Silicon 通用，Windows/Linux x64。默认仅回环，未授权真实凭据、生产部署或签名证书。计划及边界见 `.ai/docs/installers.md`，实际证据待新 head CI，不沿用旧包结论。

更新：2026-10-02。登录/MCP后续主线push CI37014419461揭示旧虚拟点恢复缺陷：人工无效计算时间阻止延迟good源时间恢复，物理值52/动作66但虚拟保持null/bad。已最小修正为仅虚拟锁内重算跳过物理乱序过滤；物理帧防护和最早依赖源时间保留。最终5变体20轮race、独立10轮、120个Go顶层测试及未改动的真实MQTT/15000点smoke通过，详情 `.ai/docs/virtual-recovery-verification.md`；最终远端门禁以对应修复PR为准。此缺陷不是登录失败；先前e7aa产物仍是有独立通过证据的旧版，不能称包含本修复。

更新：2026-10-02。内网登录与现有业务 API 的 MCP 覆盖已实现并完成隔离验证。产品 head `32607c7`，PR #10；118个顶层Go/race测试（265含子测试）、76个Flutter测试、Linux/Web release构建通过，初始head完整CI37010627839六项和生命周期37010628064成功。原生CUA证实错误/正确登录、主动退出、60秒过期、重新登录和过期时私有弹窗清理；正常关闭exit0，桌面fixture已停止。独立安全复核的问题均已修复，详见 `.ai/docs/auth-mcp-verification.md`。

默认本机模式保留并限制回环Host；显式内网认证要求用户准备bcrypt账号与受信任TLS。cookie/短期bearer共享过期/撤销、CSRF与HTTP/MCP鉴权；32个工具覆盖所有现有业务REST，默认MCP只读。未部署真实内网或创建用户持久凭据；OAuth-only MCP客户端不在兼容承诺内。后续CUA入口只增加运行时fixture环境参数，不改生产行为；最终head检查与合并状态以PR #10为准。

上一轮用户指定五项基础能力已完成：读取/写入缩放偏移、定时存储、条件存储、条件触发的受限动作序列。PR #8 产品 head `22d41721057e4b49d3c193cc51f53a6e4bdc6e07` 已合入 main `62398358c09533d93d8d4d292620937e16b15493`；完整 CI 36994103672 六项 success，关闭专项 36994103735 success。

精确远端 head 本地 80 个 Go/race 测试（含真实本地 MQTT，无跳过）、55 个 Flutter 测试及 vet/analyze/格式通过。原生 CUA 核对读取20、负倍率写15/原值10、条件预览及执行、1000ms定时约10秒新增40行；只读SQLite证明48行、一个规则执行及停止配置。实际本地tar核验59项摘要、包内换算/存储/重启/同包Web接口通过。详细证据、来源树等价关系与下载见 `.ai/docs/focused-functional-tests.md` 和 `.ai/docs/v0.1.md`。

已修复逆算不可表达目标假成功、大偏移错误读回、INT不安全范围、非有限原值污染JSON、重复开始存储重置周期、保存未变规则重放、独立作用域错误被覆盖、缺失阈值默认零、无效预览和比较运算符校验。独立复核中发现的大整数小数误舍入及十进制过零拒绝也已回归修复。

原生存储页面需点击筛选才能刷新旧计数、ATK可访问性读取警告及历史浏览器首字符丢失观察仍明确记录；本轮浏览器门禁通过，不把之前 main 的失败称为全绿。脚本不是任意系统代码；历史无独立落库时间；重启规则禁用且不重放运行样本。真实设备、长期负载、Windows人工、多工程隔离及远程认证仍未验。未部署或发布Release。

产品母本 `agent.md`，唯一活跃看板 `AI_BOARD.md`。上一轮已闭环；登录/MCP本轮证据及部署边界已记录，剩余产品缺口在 AI_BOARD.md。
