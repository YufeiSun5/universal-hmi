# Windows 2026-10-28 覆盖安装包

用户要求提供最新版可覆盖安装的安装程序。交付版本为0.1.0.5，文件为 `dist/installers/update-20261028/Universal-HMI-20261028-PG-Setup.exe`，207,051,797字节，内置PostgreSQL18.6。SHA-256：`19f7860071e8fd58d174365e79028c0e3fc0968e5129943c5aa39ac9962bf37e`。

本轮仅修改 `ci/build_windows_lazy.py`、`packaging/windows-lazy/windows-lazy.iss` 与部署说明的版本/文件名，沿用安装AppId、原安装目录、启动器和独立工程目录。无需卸载，安装前关闭窗口并运行开始菜单“停止后台”。用户数据不会随程序包替换；WebView2仍为独立前提，安装包仍未签名。

## 来源与验证

应用逐字复用[最新普通界面批次](process-surface-verification.md)的ProcessSurface-v2已编译包，源码摘要 `f71bf43201bce198f9f6d85bb8c40a74f796f8f326a3ed17009b4cb9d3bbb175`。本轮未重新编译Go/Flutter，也未重跑此前相同源码的Go全测/vet、Flutter215项/analyze和Windows/Web构建；逐项核对本轮源码差异仅限上述部署文件，安装前后验证6271个应用文件、3059个PG文件及GIS源码资源清单。没有混入工程数据库、账号或开发机凭据。

通过GitHub连接重新核对基点f552d81的CI38031925059与38031925060均success；旧CI不覆盖当前工作树。打包单元门禁27项，其中16项通过、11项按宿主平台跳过；首次因Windows默认GBK读取UTF-8文件报2项解码错误，使用PYTHONUTF8=1原样重跑通过，没有修改断言。

隔离路径实际安装昨天0.1.0.4的PG-GISFix安装包，启动已有测试PG工程并创建一个仅用于本测试的账号，再停止后台并以本次最终EXE覆盖安装，退出码0、注册版本0.1.0.5。运行/开发参数均能启动和复用后台；11张表的数量与逻辑摘要保持一致（1账号、4站点、3工程文档）。升级前创建的账号在新版登录成功；登录核验在表摘要对比之后执行，会正常追加登录审计。HTTP返回main.dart.js及GIS月球/站标脚本与安装内容逐字一致。

随后停止隔离后台并卸载测试安装，项目、PG数据及密钥完整文件摘要保持，旧SQLite目录未变；原桌面/开始菜单快捷方式逐字恢复。固定18153及真实用户工程未改动。新安装EXE没有进行本轮原生窗口/DPI/现场设备验收，后台启动和HTTP验证不能替代这些项目。

证据：[来源](evidence/20261028-installer-update/source-verification.json)、[安装升级卸载](evidence/20261028-installer-update/install-upgrade-uninstall.json)、[最终产物](evidence/20261028-installer-update/installer-manifest.json)。交付只需完整EXE，PG补充ZIP不是必需项。
