# 虚拟点延迟恢复回归（2026-10-02）

## 触发与范围

PR #10 的两个产品 head 均通过完整 CI，登录/MCP 已合并。随后相同源码树的主线提交 `5174f4d08e6ca0b8f49242b5b7d3dc96f20848a1` 在 [push CI37014419461](https://github.com/YufeiSun5/universal-hmi/actions/runs/37014419461) 的 Linux 通用 MQTT smoke 失败：物理输入条件已写入66，`ci/smoke.py:57` 的虚拟平均值53断言失败。Go/race/vet/build与Windows后端通过；该轮后续Flutter/组包被跳过，不能称该轮全绿。

根因不是登录或MCP，也不是可以忽略的测试抖动。`engine.go` 与 `ci/smoke.py` 从登录/MCP之前的 `7d64aef` 到 `5174f4d` 未修改。确定性测试复现：缺失或坏质量虚拟计算用当前评估时刻标记无效结果；稍后到达的有效物理样本虽然比该物理点的旧样本新，却早于这个人工计算时刻。虚拟结果再沿用物理样本的乱序过滤，导致正确的重算被拒绝。

结果保持 nil/bad，而非误标为GOOD；但依赖它的公式、条件和存储可能无法及时恢复。无新样本到来时仅增加等待并不能恢复。

## 修复合同

虚拟计算在同一 `e.mu` 锁内按依赖拓扑顺序执行，其结果属于当前评估而非异步收到的物理帧。仅对虚拟结果绕过物理源时间乱序拒绝；物理/模拟/手工输入仍保留原有乱序校验、类型/换算/有限数/未来时间检查。虚拟 source_time 继续取有效输入最早源时间，不用重算时间假装新鲜；坏质量/陈旧/缺失仍传播为无效。

## 确定性证据

新增 `virtual_regression_test.go`。最终测试文件在原实现的只读 overlay 上复验：missing、bad、bad-first、stale 四项失败，bad-second 原本通过。修复后五项均通过；不能将原本通过的对照项称为旧版缺陷。覆盖：
- missing→延迟good，同时证明物理条件动作66成功但平均/链式虚拟未恢复
- bad→延迟good，同样重现原始smoke症状
- good→bad-first/bad-second→延迟good：坏质量与陈旧分开验证，恢复值73且最早输入位于依赖列表第二项
- good→stale→延迟good，恢复后仍按最早输入陈旧；旧物理帧依旧拒绝

`ci/smoke.py` 精确53断言保留，不通过放宽断言、增加固定sleep或盲目重跑掩盖产品错误。修复后五项20轮race通过，独立复核10轮race通过；完整Go/race套件120个顶层/272个含子测试通过，手动CUA fixture按设计跳过。vet、module verify、格式、server build通过。原始通用MQTT与5broker/30站/15000点容量smoke原样通过。

另以只向本地测试broker延迟600ms发送已带源时间的good消息构造真实HTTP/MQTT对照：原版物理52/good、输出66/good、虚拟null/bad并失败；修正版虚拟53/good，保留原最早源时间，随后逆算写、去重、历史与XLSX断言全部通过。延迟脚本仅用于重现，不替换标准CI smoke。机读摘要见[验证记录](evidence/20261002-virtual-recovery/validation.json)。

最终远端head/CI与合并状态以对应小步修复PR为准；初始失败运行保持失败记录，不以新成功覆盖。
