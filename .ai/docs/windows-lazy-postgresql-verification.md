# Windows PostgreSQL 离线一体部署验证

本页记录初次 PG 部署验证。随后发现该包混入旧 GIS 展示脚本，文件摘要验证未覆盖正确的 GIS 源码版本；请改用 [GIS 修复版及验证](gis-package-verification.md) 中的安装程序。以下历史结果不作为 GIS 实时浮窗通过的证据。

日期：2026-10-27。用户要求把最新版重新打包部署到昨天的电脑，该电脑没有PG，并选择“懒人模式”。

## 交付契约

`packaging/windows-lazy/` 提供单EXE安装入口、运行/开发两个桌面图标、开始菜单停止后台和部署说明；安装身份与昨天v2/v3相同，原安装路径可直接升级。首次启动自动创建当前Windows用户私有的PG18集群、随机凭据与非超级用户应用角色，通过既有Go `--migrate-sqlite` 导入旧工程。架构以[唯一契约](architecture.md#windows-离线-postgresql-部署2026-10-27)为准。

没有改动Go/Flutter业务代码；复用[登录界面版本](login-style-verification.md)已通过Go全测/vet、Flutter193项/analyze及Windows/Web构建的逐字产物。应用源码摘要为 `7d3f2694f8edf29515db4404819b515fa1e40c2150ba43f4cb91bceffdab9ded`，应用构建清单保持；部署脚本、PG运行库及许可证由单独deployment-manifest记录。`ci/build_windows_lazy.py` 拒绝未重新构建的应用源码差异，冻结部署脚本并在封装完成后核对源码，避免用新摘要替旧构建背书。

PG取自[EDB官方二进制发布](https://www.enterprisedb.com/download-postgresql-binaries)，版本18.6、Windows x64；原始ZIP的SHA256为 `e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2`。保留bin/lib/share/doc、许可证及第三方声明，不包含pgAdmin运行环境；增加已验证桌面包同版应用本地VC运行库。postgres.exe本身未签名，未将本地摘要校验冒称供应商签名验证。6个核心PG程序递归解析45个PE依赖，缺失0项。

## 已完成验证

- `ci/test_windows_lazy.py` 在Windows PowerShell5.1和真实私有PostgreSQL18.6上运行，使用隔离目录和含空格路径，不连接现场；完整结果见[集成记录](evidence/20261027-lazy-pg/integration.json)。
- 全新初始化通过；18080/55432被占用时自动选空闲端口；仅127.0.0.1监听；应用角色无超级用户、建库及建角色权；没有默认应用账号；Web入口及main.dart.js逐字匹配封装产物。
- 两入口重复启动复用同一PG进程，数据库十一表计数保持；停止后台后PG/HTTP端口关闭，重启保持数据。已配置PG端口被无关进程占用时失败，不连接或停止无关服务。
- 基于昨天v3隔离数据的真实SQLite迁移：原目录和备份逐文件一致；3份工程文档逐字一致，历史数值12.5保持；重复启动及清除启动完成记录后不重复导入，重启计数保持。测试历史使用当前毫秒时间，遵守应用既有保留期。
- 损坏points.json导致迁移失败，不写迁移完成标记、不启动HTTP，原始目录不变；修复新工程副本后可重试并完成。完成标记随数据库事务提交，不依赖启动器最后一步写文件。
- 修复并验证PowerShell子进程等待、重复设置ACL、迁移默认端口占用及可移植文件摘要计算；首次初始化使用临时目录完成后重命名，保留失败诊断文件。
- 固定18153原评审服务和工程未替换；没有把开发机账号、工程、PG凭据或测试账号放入安装包。

## 安装、原生入口与卸载验收

- 使用昨天v3真实安装包先安装，再用本次最终EXE在同一安装目录升级，退出码均0；安装前后隔离旧工程逐文件一致。新安装目录的6263个应用文件、3059个PG文件，以及启动器、部署清单、全部部署源码摘要逐一核对通过。见[安装卸载结果](evidence/20261027-lazy-pg/install-uninstall.json)。
- 旧GIS/工艺图/MQTT三个图标替换为运行态和开发态两个图标；[快捷方式记录](evidence/20261027-lazy-pg/shortcuts.json)确认正确启动器、视图参数及图标。
- 实际启动Windows原生运行态与开发态，首次自动初始化PG、备份旧工程、迁移并展示创建首个管理员界面；两次启动共用后端PID36164，正常关闭客户端后后台继续运行。截图：[运行态](evidence/20261027-lazy-pg/native-runtime.png)、[开发态](evidence/20261027-lazy-pg/native-developer.png)。本批仅验原生首屏/关闭及入口，未重做登录后的全部业务人工测试；身份流程已有登录界面版本证据。
- 停止后台后卸载退出码0，工程目录、PG集群、身份密钥及备份的所有文件摘要保持，旧数据目录也保持。已恢复本机原有桌面/开始菜单快捷方式，隔离测试进程全部停止；原18153健康检查仍通过。
- 最终[安装包清单](evidence/20261027-lazy-pg/installer.json)：`Universal-HMI-20261027-PG-Setup.exe`，204243014字节，SHA256 `0b4c9dfc51c77199147595e7aae93ca8f24e1f9a7b2b39ea3570cebc326e6da8`；补充ZIP59895600字节，SHA256 `d325b433e4c36e7e74f6842d78ee4ff0369ce14657d41005fe652d5335048a01`。部署摘要 `ec2c44460752df97f04bfcbcb53857883f377770afb2d57a31f55820af63b11c`。

目标服务器尚未实际运行；本机测试不冒称现场验收。当前为登录用户启动的本机模式，不注册Windows系统服务，不开放远程监听。WebView2沿用用户前一天要求的独立安装方式。远端CI最新检查仍为f552d81c的38031925060 success，该历史结果不覆盖当前未提交部署改动。
