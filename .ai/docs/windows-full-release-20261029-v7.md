# Windows 2026-10-29 完整离线安装包 v7

按用户“重新出包”要求交付 0.1.0.7，6.1 Sol 实施封装，主代理审查和隔离安装验收。产物：`dist/installers/full-20261029-v7/Universal-HMI-20261029-Full-v7-Setup.exe`，215,852,816 字节，内置 PostgreSQL 18.6。

SHA-256：`7623809b61a4d1cc2cd21ed7c1b72d90ca6c453a8bf02ce92cd1853f3ff7d91c`。

## 范围与来源

包含四种匿名工艺模板、独立复制快建、编辑/预览一致的图片/渐变/透明度背景、新应用图标、双端单实例与关闭到托盘、自签 HTTPS 配置及独立远程双入口。公网默认关闭，IP 留空，安装不修改系统信任、路由或防火墙，不自动安装 Windows 服务。

复用本轮已验的 `dist/Universal-HMI-PublicRemote-20261029` 应用，未再次编译 Go/Flutter；应用源码摘要为 `e2a8499a12ff237c862ae8cfd7b2d78d2f649ab7ad64714fffda08ea33fbd99c`。应用构建和业务验证见[公网验证](public-remote-verification.md)。本次仅改安装配方、版本、快捷方式图标与说明，安装来源单独计证，部署摘要 `9947c1f39f4fce2d185e94b62aaf4e069fb4167df2153e9d05341b00339f3396`。

保留旧安装 AppId 和工程路径；所有启动快捷方式使用新版 EXE 图标。包内无开发机账号、证书私钥或工程数据库。

## 本次实际验证

- 安装门禁 27 项：16 通过、11 按平台跳过；远程启动器 2 项通过。
- 隔离安装 v6 后启动旧后台、创建测试账号，再停止并覆盖安装 v7；注册版本为 0.1.0.7，四入口指向新 payload。
- 安装后 6289 个应用文件、3059 个 PostgreSQL 文件与来源清单逐一匹配。
- 运行/开发启动器以 NoUI 方式复用同一隔离工程；十一张 PostgreSQL 表数量及摘要保持，旧测试账号登录通过。公网配置为 disabled、origin 为空。
- 实际 HTTP 返回的 main.dart.js、bootstrap 及六项 GIS 文件与安装内容逐字一致。
- 隔离卸载后工程、PG、密钥及旧迁移源完整保留，原桌面快捷方式逐字恢复。真实 18153 后台和用户工程未改。

本次不把复用应用的既有测试算作重新执行；未重复原生界面全测。真实公网/NAT、目标机原生 DPI、长期连接及可选 SCM 现场安装仍待验。历史 CI 不覆盖本次未提交工作树。WebView2 仍为独立前置条件，安装器未签名。

## 更新方式

使用原 Windows 账号，从托盘菜单分别退出开发端和用户端，再从开始菜单 Universal HMI 运行“停止后台”，然后直接覆盖安装，无需先卸载。点击窗口 X 会收起到托盘，不能代替退出。完整包已经包含 PostgreSQL，无需另用补充 ZIP。

证据：[安装包清单](evidence/20261029-full-v7/installer-manifest.json)、[封装审计](evidence/20261029-full-v7/package-audit.json)、[覆盖安装及数据保留](evidence/20261029-full-v7/install-upgrade-uninstall.json)。公网配置见[使用指南](public-remote-guide.md)。
