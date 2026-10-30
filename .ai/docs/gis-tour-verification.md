# GIS 演示与静态展示验证 · 2026-10-28

## 月球可见性、光照与亚洲慢转修正

本节为当日后续修正，替代下文旧亮面慢转/9.494秒与旧月面光照。实际用户Edge、NVIDIA RTX4060/ANGLE D3D11下，月球贴图就绪、投影处于视口、alpha=1仍不绘制；关闭裁剪无效，改不透明或关闭OIT后可见。最终通过公开Viewer选项`orderIndependentTranslucency:false`恢复排序透明渲染，保持淡入淡出与地球遮挡。用户随后确认“能看到”，并指出月面过亮。最终将材质亮面系数1.45降到0.90，环境项0.025，侧光(-0.75,0.16,0.64)，恢复约82%盈凸月与柔和右侧阴影；正面贴图、19,000km展示轨道、大小不改。

地球仅亚洲80°E–140°E慢转，60°E–80°E及140°E–160°E连续过渡，其他角度2.6倍；全周约7.556秒。状态机测试明确覆盖非洲、美洲即使亮面也快速通过。站标每次离地重置，实际进入可见阶段才开始错峰生长。Chrome完整运行页连续四轮记录24次入场动画及151条轨道采样，见[循环记录](evidence/20261028-gis-intro/moon-render-chrome.json)。`node ci/test_gis_tour.cjs`与5项`ci/test_stage_gis.py`最终通过。

真实Edge此前完成月球可见性诊断；最终光照在1366×768完整Flutter运行页实拍确认：[最终月面截图](evidence/20261028-gis-intro/moon-lighting-final.jpg)。2500×1435、640×360、850×600/DPR1.25与900×1200的可见性已在此前隔离Chrome核验。最终Edge自动化连接卡在页面加载检查，未取得最终光照的Edge截图，不将Chrome截图冒称用户Edge验收。为重新加载展示尝试切回GIS并刷新了当前只读运行页，没有操作开发草稿或业务保存。

固定18153和桌面共享入口为`dist/Universal-HMI-MoonRender-20261028`，编译基线RuntimeLight摘要bd3ba71c…，本批只覆盖8个web/gis文件，Go/Flutter/Web编译资源逐字保持。最终GIS来源摘要`18aa7d360f1a245a9a17c44fa85758e9baff788a1d835fc0e6db7423d5ceb05c`。首次切换前完整备份`.local/postgres/backups/20261028-162002-gis-tour`；光照调整另备份原脚本、构建清单与覆盖记录到`.local/gis-intro/lighting-backup-20261028-1635`，仅静态资源更新，未再次重启服务。最终清单/实际HTTP字节核对通过；PG十张业务表摘要不变，原11条审计保持，新增1条正常成功登录，1账号/4站点/3画面保留，见[部署核验](evidence/20261028-gis-intro/moon-render-deployment.json)。

本批没有重新编译Go/Flutter，也没有新安装EXE；原生鼠标/DPI、目标电脑和现场未验。远端旧CI success不覆盖当前工作树。普通页面UI属于另一活跃任务，本批仅GIS资源。

范围仅为 `examples/gis-flight` 的展示状态机、太空装饰与GIS发行资源；站点、变量绑定、实时数据质量及业务权限契约保持。需求以 [agent.md](../../agent.md) 为准，架构见 [GIS展示合同](architecture.md#gis开场太空装饰2026-10-28)。

## 最终行为

- 右下两个36px图标：圆环为演示模式，地图为静态展示。圆环点击立即结束当前浮窗轮播，从当前镜头1.4秒拉远，进入地球环游→飞入→站点轮播的循环；已经拉远/环游时重复点击保持进度。
- 地图图标就近进入地面，各站浮窗3.5秒、站间平移0.85秒，循环站点而不返回地球；再次点击暂停，地图图标保留并用暂停标记表示当前状态。点击地图或Esc也可手动接管。
- 首次加载仍6秒飞入。环游沿原12秒路径连续变速，亮面速度不低于原值、暗面加快，实际一周约9.494秒。隐藏页面冻结进度；减少动态时跳过空间运动和太空装饰。
- 月球使用NASA LROC正面月海与第谷坑，保持灰白、较小、远轨道，从地球后方或屏幕外连续出现；独立侧光形成略缺的盈凸月。轨道与月相是电影式构图，不代表真实星历。
- 三颗卫星使用透明色图和法线图，放慢绕行与面板转动、扩大反光窗口，仍受日照、地球遮挡及反光角约束。流星按卫星掠过方向、不同位置生成，亮核/渐细拖尾/余辉随高度降低缩小淡出。
- 编辑态不巡展，只保留原地图复位和编辑能力。运行两模式不保存配置或写设备。

## 已执行检查

`ci/test_gis_tour.cjs`通过：完整3.5秒停留、顺序与循环、就近切换、静态多轮不返回地球、演示立即中断浮窗、重复点击不重置飞行、暂停、隐藏、空站点、配置变化及减少动态。`ci/test_stage_gis.py`全部5项通过。首次以模块路径运行stage测试时因导入路径报错，改用该脚本入口执行通过，未修改断言。

真实Chrome在1440×900静态模式采样537次，连续六轮只出现station/travel，两个站点均轮播，高度始终约18500米。实际点击圆环的事件记录为`phase=return, elapsed=0, duration=1.4`，证明没有等剩余浮窗；随后28秒采样覆盖orbit/intro/travel/station/return。见[模式实测](evidence/20261028-gis-intro/modes-final.json)。

640×360两个图标完整可见，浮窗可滚动：[小窗口截图](evidence/20261028-gis-intro/modes-narrow-final.jpg)。再次点击地图图标后idle、enabled=false，600ms内镜头与轨道时钟保持。减少动态时月球绘制次数0、流星frames=0且visible=false；编辑态自动idle并仅显示“重置地图视角”。本批浏览器无console error/warn。

[月相与模式图标实拍](evidence/20261028-gis-intro/moon-gibbous-and-modes.jpg)来自实际地球环游。此前[月面细节](evidence/20261028-gis-intro/moon-nearside-inspection.jpg)、[变速环游](evidence/20261028-gis-intro/dark-speed-final.json)、[近地流星尺寸](evidence/20261028-gis-intro/controls-loop-final.json)保留为对应功能的证据。旧controls-nearest及controls-loop中的按钮文字/重置语义已由本批双模式替代。

此前本批Go全量test/vet、Flutter analyze及211项测试通过；顶部恢复后的212项测试与analyze亦通过（日志 `.local/light-ui/`）。最终GIS双模式源码的Windows/Web构建均通过，源码摘要`2ff664c379fb9b7e4a94ec21cf10aa7782bf0892fe1abee2c2c2770f1b481d6a`。但共享Web目录随后被并行构建覆盖，组合包校验以`flutter_bootstrap.js changed`拒绝混合产物；这套共享目录没有用于部署。

## 发行与边界

发行改为独立GIS展示资源更新：从当前已部署且清单完整的PerfOptimized版本复制至`dist/Universal-HMI-GISTour-20261028`，仅更新`web/gis/`的15个文件，保留已部署Flutter Web、原生程序、Go后端所有字节；清单分别记录编译基线和GIS覆盖层来源及摘要，不将资源更新冒称整应用重新编译。

固定18153已由PID62408运行，桌面双入口的project.json同步指向新版本。GIS来源摘要为`9ce00e23afbef97ccf9337dab5f8988a63e642d58f3b96fd207739a45d392af1`。备份位于`.local/postgres/backups/20261028-151531-gis-tour`；前后十一张PG表数量与逻辑摘要完全一致，原1账号/4站点/3画面保留。服务实际返回的main.dart.js、map.html、模式/轨道/流星脚本、样式及月面图片逐字摘要匹配。[部署记录](evidence/20261028-gis-intro/deployment.json)。18153隔离Chrome再次验证地图模式与点击圆环立即return；测试站点只发给隔离页面，未保存工程。

没有刷新用户原浏览器、没有引入测试站点到工程。未制作新安装EXE；原生DPI/鼠标、目标电脑、现场KingIO、长期渲染或50渲染客户端不属于本批通过项。远端基点f552d81的Verify和生命周期CI均success，但不覆盖本工作树；旧HANDOFF结果亦不作为本批验收。
