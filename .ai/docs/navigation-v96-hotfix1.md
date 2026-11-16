# v96 Hotfix1：导航元数据读取应急修复

2026-11-16，用户报告现场v96工艺图目录消失。只读核对发现目录仍返回31张工艺图和1张GIS，抽查完整图纸可读；navigation请求反复以SSL_PROTOCOL_ERROR结束。源码证实导航判权逐项Get完整图纸（包含图片展开/校验），HTTPS写超时为30秒。后者是已移除的高开销路径；没有现场服务端日志，不声称已证明TLS错误唯一根因或现场已恢复。

本分支独立基于现场交付源码fb2dbb64，仅修改Go工艺目录/导航读取及回归。`process.GetSummary`从持久化文档读取稳定ID、归属站点等元数据，`List/ListAll`同样不展开图片；导航GET使用该契约并在单次请求中复用重复目标的结果。仍按原站点/画面范围判权，并在响应前重查会话有效性。菜单保存、实际Get图纸及启动完整性检查保持原图片校验；不放宽30秒写超时，不改数据、revision、变量绑定或数据库结构。

回归覆盖文件/数据库存储模式、图片对象不可用时目录仍可读但完整图纸和重启明确失败；64次重复引用只读一次元数据，越权和缺失目标过滤，显式共享图授权与处理中撤权保持。Go定向、全量test/vet和后端release构建全部通过。源码8c5216ff已推送；完整EXE已放Downloads/导航读取应急修复_v96_Hotfix1_20261116，SHA256为`d02547443a567b340614dbae2bd130c8d588abcca0ba48cac8feeced8e565758`。证据：[Go全测](evidence/20261116-navigation-v96-hotfix1/go-all.log)、[vet](evidence/20261116-navigation-v96-hotfix1/go-vet.log)、[产物来源核验](evidence/20261116-navigation-v96-hotfix1/prepare.log)、[安装包摘要](evidence/20261116-navigation-v96-hotfix1/installer-manifest.json)。

应急包复用v96原Windows/Web客户端逐字节产物，仅重新编译后端。构建清单明确记录`reused_client`的原编译revision/源码摘要/原清单摘要，以及`backend_hotfix`的后端新摘要；聚合源码清单变化只允许本次Go文件和安装包名称。逐文件核对客户端源码及产物均保持，不把复用客户端冒称重新构建。安装器沿用既有保数据升级机制，独立版本目录/工程目录保持；不包含v97/v98物料改动，也不包含另一工作分支尚未发布的Flutter入口与目录提示修复。

未自动安装或部署现场、18153、21317。现场恢复仍须用户安装本应急包后验证原菜单和图纸。
