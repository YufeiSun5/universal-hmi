# 应用图标验证（2026-10-29）

用户要求生成美观图标并替换Flutter默认图标。6.1 Sol负责生成及接入，主代理负责方案与最终审查。使用内置imagegen生成深蓝圆角底、银白连通结构及青色节点主标；主代理查看母版、32px及128px导出，审查通过。[母版及提示词](../../app/assets/branding/README.md)。

## 实施

Windows EXE、窗口和托盘共享资源101，替换为16/24/32/48/64/128/256七档ICO。Web favicon、Apple touch及PWA图标统一替换，引用增加缓存版本；maskable提供不透明底与安全区。macOS已有七尺寸资源及Linux安装SVG包装同步更新，但未做这两平台运行验收。开发/运行快捷方式使用统一主标，名称继续区分两端。导出脚本ci/generate_launch_icons.py仅从生成母版缩放、转格式，避免重新生成旧图标。

## 本轮验证

- passed：Flutter analyze；Windows/Web release构建。构建保留既有CMake CMP0175及Cupertino字体提示，未因图标扩展修复范围。
- passed：Win32读取新EXE资源101，七档资源逐字节对应源ICO，详见[资源核对](evidence/20261029-app-icon/resource-proof.json)。新EXE SHA256为15f6642687b61568a099cb3e5840100e2a21b84c402e2490c7dae4c0d104c660。
- passed：两桌面快捷方式IconLocation指向本轮版本化ICO，启动参数不变，见[快捷方式记录](evidence/20261029-app-icon/desktop-deploy.json)。
- passed：固定18153的七个入口/图标HTTP响应核对；5208个保护文件（含5204 GIS文件、main.dart.js、bootstrap、server和project.json）哈希保持，见[发布覆盖记录](evidence/20261029-app-icon/icon-overlay.json)。
- passed：主代理检查源引用与导出脚本，使用core.whitespace=cr-at-eol执行相关文本diff检查通过。
- unexecuted：本轮纯资源改动未重跑业务单测或Go检查；不将上一轮235项测试称为本轮结果。未执行物理托盘鼠标/DPI矩阵、macOS/Linux原生运行或新安装包验收。

## 本机交付

2026-10-29 12:35追加实际应用：用户再次要求换上图标，核查发现正在运行的两端仍是旧ProcessSurface-20261028-v2程序（PID25236/24128）。6.1 Sol备份并将桌面两个快捷方式的IconLocation重新指向新缓存路径icons/universal-hmi-applied-20261029-123557.ico，逐项回读确认启动参数和其他属性不变，并发送Shell UPDATEITEM/UPDATEDIR刷新通知。开始菜单及用户固定栏未找到其他HMI链接。证据在.local/app-icon/apply/20261029-123557/apply-result.json；未关闭旧窗口或停止服务。

在dist/Universal-HMI-DesktopLifecycle-20261029上仅覆盖新EXE和图标相关文件，增记icon_overlay-20261029.json；原build-manifest为历史完整构建证据，不冒充本次整包同源结果。旧EXE、快捷方式及配置备份在.local/app-icon。未结束用户窗口、重启18153后台或修改工程数据；已打开旧程序需用户明确退出后重开才能使用新嵌入图标。本轮未制作安装EXE。
