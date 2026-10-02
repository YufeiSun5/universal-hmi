# 唯一活跃工作看板

更新：2026-10-02。PR #1–8 已合并。上一轮用户指定五项基础能力及精确 head 验收已完成；当前推进登录/MCP，证据见 `.ai/docs/focused-functional-tests.md` 与 `.ai/docs/v0.1.md`；母本仍为 `agent.md`。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| UX-03 | open | 原生历史页进入时刷新旧计数的可见性 | 当前点击筛选显示真实结果；不影响已证实的后台落库 |
| UX-02 | open | Windows 人工交互/DPI/多屏/生命周期 | 独立 Windows 真机证据；Linux 证据不替代 |
| PROTOCOL-01 | open | 真实设备厂商协议、ACK/读回 | 本地 broker 模拟不冒充现场验收 |
| SCALE-01 | open | 长期负载及流畅度 | 已有 5来源/30站/15000点证据；total P99 约60ms，不承诺60FPS |
| PROJECT-01 | open | 独立多工程隔离与切换 | 当前为单本地工程、多站 |
| AUTH-01 | in_progress | 内网登录、会话/权限与前端过期恢复 | 隔离正确/错误登录、注销/过期、HTTP/MCP绕过与TLS/来源检查；不擅自部署 |
| MCP-01 | in_progress | 现有业务 API 完整 MCP 覆盖 | 固定工具清单、读写限制、严格输入与业务回归；不开放任意脚本 |
| BASE-01 | open | SPT 独立 Lite 来源核实 | 不把参考文档称为源码迁入 |

已解决的旧 ENV-01 和 RELEASE-01 不再作为当前阻塞。新一轮成功只以本轮测试及最终提交为证。
