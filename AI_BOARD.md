# 唯一活跃工作看板

更新：2026-10-10。PR #1–8 已合并。上一轮用户指定五项基础能力及精确 head 验收已完成；登录/MCP本轮已完成隔离验证，PR #10最终head检查及合并以远端为准，证据见 `.ai/docs/focused-functional-tests.md` 与 `.ai/docs/v0.1.md`；母本仍为 `agent.md`。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| PROCESS-01 | in_progress | 免费工艺 SVG、共享透明 PNG、通用开发页、新建模板、参考供热站蓝图/组件适配；属性提交、左键绘制、四边缩放；管道拼接/撤销/角度、伪3D/圆角/弯头、参考线、箭头分布/动画/反向/条件、模板绑定隔离；素材端口随等比内容框与旋转对齐 | 最新素材修复 Go test/vet、Flutter analyze/131项/68文件只读格式、Python3项、Windows/Web release+verify-only passed（源码c8ecdd90…，基线10af848）；四自绘设备×四方向实际像素连接 passed；真实 Chrome 右边拖宽/新管吸附/撤销、960×480与640×360嵌入连续 passed。此前管道180a2896…/128项及文字/四尺寸/透明PNG证据保留。18139仅更新Web，三张用户画面字节不变，未刷新用户页。10af848 CI38022212602 / 生命周期38022212630 success；本修复新head与用户评审以 PR #14 为准。证据和边界见工艺画面说明；保存解码诊断11类与管道全部字段HTTP回归、实际v3保存重开及Go/Flutter131项/Windows-Web构建通过；18139后端已更新，用户原文件不变。原截图失败请求待用户重试，具体根因尚未确认。保存证据见工艺画面说明 |
| INSTALL-03 | in_progress | Windows/Linux/macOS 原生安装器及同包 Web，广泛回归与实际截图 | 对应 OS CI 安装/更新/卸载、包内 Web 字节核对；Linux 实际安装展示；不声称未执行的原生人工测试 |
| UX-03 | open | 原生历史页进入时刷新旧计数的可见性 | 当前点击筛选显示真实结果；不影响已证实的后台落库 |
| UX-02 | open | Windows 人工交互/DPI/多屏/生命周期 | 独立 Windows 真机证据；Linux 证据不替代 |
| PROTOCOL-01 | open | 真实设备厂商协议、ACK/读回 | 本地 broker 模拟不冒充现场验收 |
| SCALE-01 | open | 长期负载及流畅度 | 已有 5来源/30站/15000点证据；total P99 约60ms，不承诺60FPS |
| PROJECT-01 | open | 独立多工程隔离与切换 | 当前为单本地工程、多站 |
| AUTH-DEPLOY | open | 操作方内网证书/账号配置及实际网络验收 | 源码及隔离登录/MCP已验；不擅自创建持久访问或部署，见认证合同 |
| BASE-01 | open | SPT 独立 Lite 来源核实 | 不把参考文档称为源码迁入 |

已解决的旧 ENV-01 和 RELEASE-01 不再作为当前阻塞。新一轮成功只以本轮测试及最终提交为证。

登录/MCP已完成项的详细证据在 [.ai/docs/auth-mcp-verification.md](.ai/docs/auth-mcp-verification.md)，包含独立复核问题与修复，不作为新的重复活跃项。

虚拟点延迟恢复已定位并完成本地/独立红绿回归，原始断言不放宽；最终修复PR门禁与失败记录见 [.ai/docs/virtual-recovery-verification.md](.ai/docs/virtual-recovery-verification.md)。
