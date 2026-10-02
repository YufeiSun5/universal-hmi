# 唯一活跃工作看板

更新：2026-10-02。PR #1–8 已合并。上一轮用户指定五项基础能力及精确 head 验收已完成；登录/MCP本轮已完成隔离验证，PR #10最终head检查及合并以远端为准，证据见 `.ai/docs/focused-functional-tests.md` 与 `.ai/docs/v0.1.md`；母本仍为 `agent.md`。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| UX-HISTORY-MCP | in_progress | 500点站点实用历史报表/完整时段曲线，以及可见MCP模式与连接测试 | 原生15k实际可见；有界全时段查询/最多6点比较/时间筛选；MCP保持认证及启动权限上限 |
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

三平台安装任务已在 PR #12 合入 main `b8d3b77`，最终主线 [CI 37034415067](https://github.com/YufeiSun5/universal-hmi/actions/runs/37034415067) 十项通过；具体产物与原生安装边界见 [.ai/docs/installers.md](.ai/docs/installers.md)。本轮用户进一步要求实际展示30站每站500变量、改善报表/曲线和MCP开关测试，继续以上唯一活跃项。
