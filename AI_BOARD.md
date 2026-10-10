# 唯一活跃工作看板

更新：2026-10-10。PR #1–8 已合并。上一轮用户指定五项基础能力及精确 head 验收已完成；登录/MCP本轮已完成隔离验证，PR #10最终head检查及合并以远端为准，证据见 `.ai/docs/focused-functional-tests.md` 与 `.ai/docs/v0.1.md`；母本仍为 `agent.md`。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| PROCESS-01 | in_progress | 免费工艺 SVG、共享透明 PNG、通用开发页、新建模板、参考供热站蓝图/组件适配；2026-10-10 属性点击提交、左键拖动绘制、四边/四角缩放；管道拼接/绘制撤销/自由角与步长、箭头分布/动画/多变量条件、模板实际绑定隔离、水平防偏移、伪 3D、圆角/半径/弯头、智能参考线/吸附、整条箭头总数与反向流动 | 本批 Go test/vet、Flutter analyze/128项/65文件只读格式、Windows/Web release+verify-only passed（源码180a2896…）；真实 Chrome 水平防偏移/绘制撤销/保存配置、中部拼接、参考线、模板实例绑定、三个反向运动箭头/实时条件、同一640×360弹窗变化且revision不变 passed。此前文字/四边/四尺寸/透明PNG证据保留。18139服务更新且原三张画面字节不变，未刷新用户页。基线 f6cbc01 CI38016543298 / 生命周期38016543300 全绿；新提交远端检查与用户评审以 PR #14 为准。证据、文件组织/容量限制见工艺画面说明 |
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
