# 接管状态绿色条件修正 v68

2026-11-10 用户要求只有温度、曲线、时间模式显示绿色。原判定额外包含手动阀门开度 valve 和旧 auto，因此存在误绿。

本批仅修改 backend/internal/overview/control.go 的只读展示状态。上游 D:/DEV_D/heatnet-valve-control/web/src/StationSettings.tsx 明确 manual=手动温度、curve=固定温度曲线、schedule=时间模式、valve=手动阀门开度；绿色仅接受前三者。valve 返回未接管，旧 auto、空值和未识别模式返回状态未知，均 active=false。

既有站区匹配、运行 AUTO、数据健康、未暂停、未回退现场、写入启用、恢复等待和接口失败判断保持。此处只决定监控展示颜色，不改变上游控制配置、设备状态或写入权限。前端继续消费 active，不复制模式判断。

## 验证与交付

更新真实上游语义的测试基线，覆盖三种有效模式及 valve/auto/空值拒绝；Go 全量 test/vet 和 Windows/Web 构建通过，完整包已交付。实际隔离后台接口验证 manual/curve/schedule 为 true，valve/auto/idle/空值为 false；从温度切为手动阀门开度后撤色，数据不健康时全部撤色；上游仅有 GET 请求且无凭据。见[实际接口证据](evidence/20261110-v68/control-api.json)。

Flutter 代码与样式无变化，沿用 v67 的前端测试结果，不重复宣称为本批重测。Windows/Web 源摘要一致：84db2951b6c02329a8bd43f23b831813a9642baa0b77a317939a3e17be5b0fb5。未部署现场或 18153，未重跑安装覆盖/卸载矩阵。

基点 v67 的远端 CI 已核对：Windows 后端、Android、Linux生命周期通过；Linux 的 KP 脚本测试缺少安全上下文 fixture 导致 serviceWorkerVersion 访问 undefined，macOS server 测试10分钟超时，Flutter矩阵未执行。两项另列待处理，不作为本批 Windows 状态判定验收通过或跨平台全绿的依据。

交付：`D:/Users/SunYufei/Downloads/Universal-HMI-20261110-Full-v68-Setup.exe`（268541613字节），同目录附 `v68-接管状态修正-说明.txt` 和 `v68-SHA256.txt`。SHA256：`6f33d8ae3facead9dbdd58c7919591d333c7a6fa7f14fb9d6b53399996790b97`；复制后摘要一致。包包含 v67 内网 HTTP 功能，按原安装位置升级后台并刷新浏览器后生效。见[交付清单](evidence/20261110-v68/release.json)。本批远端 CI 与本地验证分列，不自动合并或部署。
