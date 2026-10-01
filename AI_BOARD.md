# 唯一活跃工作看板

更新：2026-10-01。现有配置骨架可编译；第一版正在实施，不能视为现场验收。

| ID | 状态 | 工作 | 验收 |
| --- | --- | --- | --- |
| ENV-01 | blocked | 会话 Linux 环境 pending/offline，等待恢复；CI Linux 验证继续 | 区分当前环境、CI 自动测试和人工桌面验收 |
| FLOW-01 | in_progress | 点位→激活→实时→独立存储→查询→导出完整闭环 | 30 站模拟、坏质量/乱序/故障及文件重新读取 |
| EVENT-01 | in_progress | AND/OR、持续/冷却、边沿/周期/恢复及逐步动作记录 | 未知输入不触发、重复命令与部分成功 |
| UX-01 | open | Flutter 紧凑工作空间、属性面板、趋势、键盘与文件操作 | Linux/Web 构建与自动交互；实际桌面验收单独记录 |
| ANALYSIS-01 | in_progress | Excel/CSV 工作表与列映射预览、筛选统计、任务导出 | 类型/时间错误不静默导入，XLSX 重新读取 |
| BASE-01 | open | 选择性复用 SPT，独立 Lite 具体源码待定位 | 不将 Lite 文档当作迁入源码证据 |
| PROTOCOL-01 | open | 真实 MQTT/写入/ACK 协议样例 | 当前声明兼容范围；generic 写入不冒充厂商兼容 |
| SCALE-01 | open | 真实点数、频率和保留待确认 | 30 站模拟不等于现场容量认证 |

已完成骨架和构建证据归 .ai/docs/initialization.md；本看板不保留已完成工作。
