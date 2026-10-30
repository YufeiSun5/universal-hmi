# Windows 2026-10-28 全量重编译安装包 v6

用户反馈上一包安装后仍显示旧界面或缺少改动，明确要求重新出包并包含所有改动。本次交付 **0.1.0.6**：`dist/installers/full-20261028-v6/Universal-HMI-20261028-Full-v6-Setup.exe`，206,936,947 字节，内置 PostgreSQL 18.6。SHA-256：`7f289fe42172ea3ba89daf19b7d14e09431841839fcd2a70e4cbca6155c07f77`。

## 构建范围

以当前工作树905份构建来源为输入，摘要 `9ed9f77fbcd3e18f6c101d4bf4c588c516e76b65c4a65abf67008e7cd80c379b`。Go后端重新构建，Windows/Web原输出目录移至隔离备份后从空目录重新编译；包含设备台账、扫描跨页选择、性能优化、普通页/工艺区/紧凑目录及最新GIS月球光照、亚洲慢转、落地站标动画。源码在测试、编译和安装封装前后保持一致，Windows/Web同源身份与全部文件摘要校验通过。

应用文件与上一包相比不再带仅用于本机共享评审工程的Start-Project.ps1；正式离线安装仍由Start-HMI.ps1负责，并生成运行态/开发态双入口。原安装AppId及用户工程路径保持。没有包含开发机账号、凭据、工程数据库或测试数据。

## 本轮验证

- Go 1.24.7 mod verify、全量test/vet、服务build通过；Flutter锁文件、127文件只读格式、analyze、215项test、Windows/Web release通过。
- 安装门禁27项（16通过、11按平台跳过）、GIS资源5项与巡展状态机通过。首次把集成脚本当unittest调用得到0 tests，已改为正确安装门禁；没有修改断言。首次安装封装缺少许可证目录，补入仓库原始许可证、记入artifact清单后重封装通过，无需改动应用二进制。
- 实际0.1.0.5→0.1.0.6覆盖安装退出0，注册版本0.1.0.6；桌面双入口参数指向新payload。6270应用文件与3059 PG文件逐项验证通过。
- 运行/开发启动复用同一隔离工程；十一张PG表数量及逻辑摘要保持。原测试账号可登录，main.dart.js、bootstrap及六项GIS实际HTTP响应与新安装文件逐字一致。
- 隔离卸载保留原工程/PG/密钥，旧SQLite目录不变；真实用户原快捷方式已恢复。固定18153及真实用户工程未改。

用户目标电脑“旧界面”的具体原因尚未在目标机复现，不把完整重编译当作根因已查明。目标机原生窗口/DPI/现场设备未验。本次核查远端基点f552d81的CI38031925059/38031925060仍success，历史CI不覆盖当前工作树。

安装时先关闭旧窗口并从开始菜单停止后台，再覆盖安装，使用桌面新运行态/开发态入口；浏览器仍显示旧页时强制刷新。WebView2仍独立安装，本包未签名。

证据：[构建结果](evidence/20261028-full-rebuild-v6/build-result.json)、[来源](evidence/20261028-full-rebuild-v6/source-verification.json)、[覆盖安装与保留数据](evidence/20261028-full-rebuild-v6/install-upgrade-uninstall.json)、[产物](evidence/20261028-full-rebuild-v6/installer-manifest.json)。
