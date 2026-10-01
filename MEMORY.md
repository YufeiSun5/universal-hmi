# 当前上下文

更新：2026-10-01。产品要求母本 agent.md，唯一看板 AI_BOARD.md。

用户已授权直接实施第一版完整功能与 UI，完成可运行版本再评审；先在 Linux 开发调试，Windows 最终构建。当前会话云环境仍 pending/offline，正在等待恢复；GitHub Actions Linux 虚拟机用于真实编译与自动流程验证，两者分别报告。

原有工程骨架已有 4/4 CI 成功，证据见 .ai/docs/initialization.md。正在扩展规范化采集、运行配置激活、虚拟公式、条件事件、受控写入、SQLite 独立历史、Excel/CSV 导入与异步报表。SPT 通用能力作为已审参考，本批实现没有复制其检测业务或声称 Lite 源码已经迁入。

优先用显式启动的 30 站模拟源验收；任何生产来源均不自动连接。MQTT 采集支持明确 generic/Kepware values/KingIO Objs 契约，物理下设只开放 generic 命令协议，厂商下设与设备 ACK/读回仍待实际样例验收。存储恢复不依赖检测，物理事件重启默认禁用以避免未知结果重放。

第一版仍在实施；不因代码提交或 CI 排队宣称功能与人工 UI 验收完成。
