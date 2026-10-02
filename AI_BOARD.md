# 唯一活跃工作看板

更新：2026-10-02。上一轮 PR #1–7 已合并，旧版本完成记录见 `.ai/docs/v0.1.md`。本轮只推进用户指定的五项基础能力；母本仍为 `agent.md`。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| BASIC-08 | in_progress | 读写缩放/偏移、定时存储、条件存储、条件动作专项 | 真实数据库行及 MQTT 载荷，边界/重复/重启回归，精确 head CI 与组包；场景见 `.ai/docs/focused-functional-tests.md` |
| UX-02 | open | Windows 人工交互/DPI/多屏/生命周期 | 独立 Windows 真机证据；Linux 证据不替代 |
| PROTOCOL-01 | open | 真实设备厂商协议、ACK/读回 | 本地 broker 模拟不冒充现场验收 |
| SCALE-01 | open | 长期负载及流畅度 | 已有 5来源/30站/15000点证据；total P99 约60ms，不承诺60FPS |
| PROJECT-01 | open | 独立多工程隔离与切换 | 当前为单本地工程、多站 |
| AUTH-01 | open | 远程认证/权限及部署 | 当前回环监听，不擅自部署 |
| BASE-01 | open | SPT 独立 Lite 来源核实 | 不把参考文档称为源码迁入 |

已解决的旧 ENV-01 和 RELEASE-01 不再作为当前阻塞。新一轮成功只以本轮测试及最终提交为证。
