# Windows完整发行v8（2026-10-29）

本次按用户批准的工艺迁移方案交付，由6.1 Sol构建封装、6.1 Terra执行隔离安装验证，主代理审查和部署。[功能及使用](process-transfer-verification.md)；产品与技术合同仍以agent.md及architecture.md为准。

## 产物

- 安装包：`dist/installers/full-20261029-v8/Universal-HMI-20261029-Full-v8-Setup.exe`，版本0.1.0.8，216466987字节，内置PostgreSQL18.6。
- SHA256：`d37ea03b570dd6634d367bdefee976493dca6225f2e8f98de06b64e8540129d7`。
- 应用目录：`dist/Universal-HMI-ProcessTransfer-20261029`。全新Go、Windows与Web构建；6339个应用文件、5739个Web文件、5204个GIS文件、3059个PG文件及48个静态工艺资料文件。
- 工艺资料：`outputs/工艺图与变量绑定导入资料-20261029.zip`，1073025字节，SHA256 `0bbb80e8156c4224be537089ce9527e3cbad128b5bc1ef234320ceaf01156675`；解压后按README使用。
- 应用来源摘要：`524842ae6170692bbbd47a0cbc8ddfa1d7e4a7ff55e91e26467d5fcd8bea5eb3`；部署来源摘要：`11ea33b976c4528f291daa6b81eda114c3203a4b86f490e23231d61c72ad21c3`。

## 已核验

1. Go全测/vet、Flutter249项及最后14项专项/analyze通过；fresh Windows/Web和封装清单通过。最初格式门禁、Python编码与GOROOT环境失败保留日志，修正后重新成功，不计为首次成功。
2. 使用实际v7与v8安装EXE，隔离工程位于.local/full-v8-installer-verification，HTTP18080、PG55432。先确认无既有同AppId注册，再执行覆盖安装；6339应用/3059 PG文件逐项哈希一致。
3. 升级前后11张PG表摘要一致、原测试账号成功登录、实际Web/GIS响应字节一致。运行与开发启动器以NoUI验证；本批没有原生双端窗口验收。
4. 实际卸载后隔离工程、PG、密钥和迁移源保留；finally逐字恢复原四个快捷方式。随后主代理另行备份并将四个已有快捷方式更新至新发行目录，保留视图和其他参数。
5. 固定18153停止后完整备份至`.local/postgres/backups/20261029-162619-process-transfer`，只切换project.json的app/server/web路径。启动新后台后真实11表摘要不变（1账号、4站点、3文档、25审计），GIS5204文件逐字一致，实际Web/GIS响应与新清单匹配，原数据库/远程配置字节保留。未导入测试数据或候选，不刷新用户旧页面、不关闭旧窗口。

升级其他电脑前先从托盘退出两端，再停止该工程后台，备份后覆盖安装。现场公网IP仍留空，公网默认关闭；真实NAT和KIO现场验证不在本次范围。WebView2沿用独立前置要求；旧远端CI不覆盖当前未提交工作树。

## 证据

- [构建与内容核验](evidence/20261029-process-transfer-release-v8/package-audit.json)、[安装清单](evidence/20261029-process-transfer-release-v8/installer-manifest.json)。
- [实际隔离安装结果](evidence/20261029-process-transfer/installer-result.json)、[18153部署](evidence/20261029-process-transfer/final-deployment-evidence.json)、[四入口更新](evidence/20261029-process-transfer/final-shortcuts.json)。
- 本机凭据、数据库备份、隔离state.json留在.local，不随发行或文档证据提供。
