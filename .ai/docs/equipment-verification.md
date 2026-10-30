# 设备台账首版验证

2026-10-28。基点f552d81；本批工作树改动不由基点CI覆盖。远端基点CI 38031925059与生命周期38031925060均success。

实现：backend/internal/equipment、server/equipment.go、cmd装配；Flutter features/equipment、main与monitor导航。独立台账数据和图片，不改采集/变量/控制。

目前Go全测/vet和四项台账widget通过。首轮Go运行发现环境GOROOT指向1.25.5，与指定1.24.7冲突，改为显式GOROOT后全测通过。Flutter analyze最终无问题。完整Flutter、Windows/Web及浏览器交互、PG持久化和部署正在验证。

阶段追加：初版197项Flutter与Web/Windows构建通过。用户随后取消人工在用/维修状态，已移除相应UI并允许无status档案；新Go全测/vet、analyze、4项台账widget、Web/Windows同源构建（db3fef02bd21b0a7d4e6fd6933478d7ca69ff94381bc855dba56ade551f77712）通过。隔离PG实际新增无状态档案、属性及图片、409冲突拒绝、服务重启后相同revision/图片摘要回读通过，见evidence/20261028-equipment/postgres.json。旧阶段真实Chrome已验证编辑保存及800×600详情，但不作为最终追加功能验收。

用户最新追加开发态绑定故障/运行变量及简单公式、运行态自动状态，正在实施。上述静态阶段证据不覆盖该追加；尚未升级原工程。18153旧GISFix服务在检查时无监听，已用原程序与原PG/工程恢复（工具管理前台进程），未刷新用户页面。组合后台启动命令被自动审批拒绝（blocked by policy），改用已核对PID的独立停止及工具管理前台进程；Chrome连接器文件路径映射拒绝上传/截图落盘，未据此宣称文件选择器验收成功。

## 自动状态最终验证（2026-10-28）

实现以[架构合同](architecture.md#自动状态实现)为准：equipment拥有可选故障/运行绑定及受限公式，runtime公开端口提供已授权的工程值与质量，Flutter只展示后端结果。开发态维护档案、图片、变量绑定及公式；运行态只读。故障优先，未绑定/输入无效/离线不能冒充停止。

- **passed**：Go 1.24.7 `go test -mod=readonly ./...`、`go vet -mod=readonly ./...`，包括优先级、公式限制、坏质量/陈旧/离线、跨站与虚拟依赖权限、revision和缓存失效/失败保存回归。输出见[Go](evidence/20261028-equipment/go-final.log)和[vet](evidence/20261028-equipment/vet-final.log)。
- **passed**：Flutter 3.35.4 analyze无问题、完整199项测试（台账6项，覆盖变量选择/保存及迟到响应/断网结果退役）；[analyze](evidence/20261028-equipment/analyze-final.log)、[测试](evidence/20261028-equipment/flutter-final.log)。
- **passed**：Windows/Web release同源摘要 `0d3ba318b964563971d3aaf7e43edbe051c1f774f5e7d7b60a9d2d488cd6c39f`，后端SHA256 `5a6c8a264de5f51c4c53dc50ce17fcfa43f32cdec8586649469245517467345b`；[Windows](evidence/20261028-equipment/windows-final.log)、[Web](evidence/20261028-equipment/web-final.log)。打包器检查源码、锁、产物摘要以及GIS来源后通过。Windows首次封装发现输出目录残留旧后端、与provenance不符，检查正确拒绝；使用当前后端重新Windows构建后再次封装通过，未放宽检查。
- **passed**：隔离PostgreSQL工程通过HTTP保存两条测试变量和设备绑定，手动样本依次故障→运行→停止；真实Chrome搜索“电流”、选择变量、保存`x >= 3 && x <= 16`并由API核对。重启后公式和revision保留，无样本时未知，新样本到达后运行。[API/持久化证据](evidence/20261028-equipment/status-api.json)。测试只使用隔离手动变量，不连接设备。
- **passed**：真实Chrome开发活动栏/台账入口、变量搜索/区间公式/保存；同一工程师账号运行态无新增编辑入口；列表和档案连续显示故障/停止/运行、未配置、断服务离线，图片正常显示。1480×900侧栏和800×600滚动弹窗已查看，断服务前控制台无错误。[浏览器记录](evidence/20261028-equipment/browser.json)。刻意停服后的网络错误属于预期；重启原会话失效需重新登录。
- **unexecuted**：本批Windows原生鼠标/DPI、图片原生文件选择器、真实KingIO/现场变量、长期50人容量。图片上传/回读/重启摘要通过HTTP验证，不能称为文件选择器已验收。未制作新安装EXE，桌面/Web组合目录用于本机评审升级。

固定18153与桌面双入口已升级到`dist/Universal-HMI-Equipment-20261028`，原工程/账号不变，旧程序目录保留可回滚。停服后备份PG dump、完整工程目录、密钥及入口配置，备份`20261028-093258-equipment`；部署后核对十一表数量和逻辑摘要完全一致（1账号、4站点、3画面文档），服务提供的Web脚本与本批摘要一致。测试账号/设备/点位未复制进原工程，隔离服务和测试浏览器已关闭，原用户浏览器未刷新。[部署证据](evidence/20261028-equipment/deployment.json)。
