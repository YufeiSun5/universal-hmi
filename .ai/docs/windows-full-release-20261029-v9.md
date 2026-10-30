# Windows完整发行v9（2026-10-29）

用户明确要求只交付完整安装EXE，所有资料也不要压缩包。由6.1 Sol封装、6.1 Terra隔离安装验收、主代理审查。应用功能和验证见[客户端历史](client-history-verification.md)，产品要求仍归[agent.md](../../agent.md)。

## 范围与来源

复用已验 `dist/Universal-HMI-ClientHistory-20261029` 的Go、Windows与Web，应用源码摘要 `a4407c04cac8d53b8d9d1d6c7cc1ffcf2c8ae31ab9505da48bf2bd7364a5a1d9`。独立安装stage为 `dist/Universal-HMI-ClientHistory-Full-v9-20261029`，只将delivery中的KingIO资料ZIP替换为6个展开文件，其余应用字节保持。绑定资料含28图、385变量和471已配关系，仍由用户显式选择真实来源后导入，不因安装自动改工程。

安装版本0.1.0.9、内置PostgreSQL18.6；关闭额外PG补充ZIP输出，安装说明不再要求解压资料。应用不重新编译，部署脚本/清单独立计证。既有18153和现用ClientHistory目录不改动。

## 验证状态

安装EXE已完成：`dist/installers/full-20261029-v9/Universal-HMI-20261029-Full-v9-Setup.exe`，215991875字节，SHA256 `8362ff33c39bd2d5fd82449749fa8a0ea495684b906f30a73e013b59beb1bf06`。主代理独立复核EXE摘要与清单一致；输出目录仅EXE、JSON清单、TXT校验及说明，无压缩包。

6个绑定资料与原已验资料逐字一致；其余应用字节保持，GIS5204文件与live一致，PG3059文件校验通过。关闭补充包分支的3个supplement字段均为null，SHA256文件仅包含EXE；安装说明不再要求解压。[封装证据](evidence/20261029-client-history-full-v9/build-result.json)与[无压缩包检查](evidence/20261029-client-history-full-v9/no-supplement-verification.json)。

隔离v8→v9实际安装、覆盖升级及卸载通过：6297个应用文件和3059个PG文件逐项一致，11表摘要不变，旧测试账号登录、实际Web/GIS HTTP字节通过。安装后的6个绑定资料文件逐字一致，28图/385变量及重试包一致；卸载保留工程、PG、密钥与迁移源。四个原桌面快捷方式逐字恢复，现用18153 PID3908和project.json保持。[脱敏安装验收](evidence/20261029-client-history-full-v9/install-upgrade-uninstall.json)。

本轮运行/开发端验证为NoUI启动器，未重测原生GUI或现场连接；应用业务沿用客户端历史已验版本。WebView2仍是目标电脑前置依赖，未打入安装包。安装器为未签名内部试用版本。

## 交付

只向用户提供上述最新完整安装EXE；资料以普通JSON/Markdown文件安装到版本目录的`delivery/process-kingio-bound-20261029`。旧ZIP仅作历史记录与构建来源，不作为本轮交付。覆盖安装前从托盘分别退出开发/用户端，再从开始菜单停止后台；同一Windows账号覆盖安装保留原数据库、账号和工程。
