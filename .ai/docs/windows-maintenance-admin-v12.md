# 管理员工程维护兼容修复（v12）

状态：实现、审查和本机隔离安装验收通过，交付 v12 完整 EXE；现场升级未执行。产品要求以 [agent.md](../../agent.md) 为准，任务以 [AI_BOARD.md](../../AI_BOARD.md) 为准。

## 现场证据与原因

用户提供的 2026-10-29 22:46:38 只读诊断确认：安装版本为 0.1.0.11，维护脚本 SHA256 为 `c0c89c7e53dd73df6dc7783b78615992a984bbcd9e58f19b090ef4e1cf48895e`，PowerShell 解析错误为 0。当前 Windows 用户为内置 Administrator（RID 500），管理员角色已启用；工程目录所有者为 Administrators 组（SID `S-1-5-32-544`），DACL 受保护，当前用户有显式 FullControl。默认工程已初始化，维护与备份目录均不存在。

v11 在创建维护目录、备份和调用重建 CLI 之前要求目录 owner 等于当前用户 SID，因此会在此工程上拒绝。这与现有启动器给当前用户及 SYSTEM 设置私有 DACL、但保留 Windows 默认目录 owner 的行为不兼容。此次拒绝尚未进入备份或数据库清理；不能由其他未知现场操作推导额外数据状态。

## 修改范围与约束

- Sol 修改 `packaging/windows-lazy/Reset-Project-v10.ps1` 和脚本测试；另一 Sol 修改安装器、说明并封包；Terra 执行独立隔离安装验收，root 审查。
- 当前用户所有的目录沿用既有规则。Administrators 组所有的目录，额外要求管理员角色已启用、受保护 DACL、当前 SID 显式 FullControl 覆盖目录与子项、无 Deny、无其他不受信任主体写权限。其他 owner 或仅组授权不放行。
- 不更改源工程 ACL。仅本次新建的私有维护目录可将默认组 owner 规范化为当前用户；已有目录须先通过授权检查，不能接管陌生目录。
- 安装器在持久安装日志旁分配新诊断文件；脚本早期失败也尝试以 CreateNew 写入阶段、固定安全错误码、异常类型和脚本栈。不写原始异常 Message、配置、密码或 DSN。文件已存在时不覆盖；安装器仅显示白名单阶段/码与路径。
- 冷备校验、重建事务、固定 `process-rebuild-v10` 标记、重复执行保护与启动闭锁不变。v12 仅更新部署，不再次编译或修改已验应用。

## 验证

- 已通过：独立同源 Inno 小包两次早期失败均退出 42，日志含阶段/错误码及持久诊断路径；重复同日志路径生成新诊断，首次文件及测试工程根 ACL 不变。证据：`.local/v12-inno-diagnostic-test/verification.json`。
- 已通过：维护脚本 12 项回归，含 11 个真实 .NET ACL 对象策略用例、新建组 owner 目录的模拟规范化及早期诊断不覆盖。脚本 SHA256：`d6d5c8e4aa7b80ac9dc4a116324f00d9d5b5bb8cac45f661c912045152eb8e7a`。证据：`.local/v12-reset-tests/script-tests.log`。
- 已通过：最终 v12 EXE 的隔离 v11→v12 覆盖升级，普通升级 623 合成扫描点及 PG 11 表摘要不变；显式重建保留 MQTT/GIS/账号/历史、完整冷备逐文件核验和实际恢复、重复维护保留新配置、卸载保留工程。应用 6301 文件和 PG 3059 文件核验、既有账号登录、HTTP GIS 字节核验通过，四原快捷方式恢复、隔离端口释放。[最终安装验收](evidence/20261029-process-match-fix-full-v12/installer-verification.json)。
- 未执行：现场升级和真实提升管理员令牌安装。本机令牌未提升，管理员组为 deny-only；内存 ACL 策略测试不等同于真实 RID500 运行。不得将原 v11 普通用户隔离通过写作管理员现场验收通过。

未访问现场 MQTT 或更改本机 18153 工程。用户报告只用于诊断；含机器 SID 的原报告不复制进公开证据。

## 交付身份

`dist/installers/full-20261029-v12/Universal-HMI-20261029-Full-v12-Setup.exe`，版本 `0.1.0.12`，225091023 字节，SHA256 `912bedd0f2bb72796474f3478de06e224f14fecf23cc07e70a663d6db4a7c09b`（root 独立核对）。应用字节复用本轮已验 `9c50cfc1…`，deployment 为 `a5e6b9ec56b11dc23bae2614904cdff8d8023ebb98b204065ab4801d4f7c3af9`，仅五项部署/测试输入变化，没有新编译业务应用。GIS 5204 文件、PG 18.6 与九个普通资料文件校验通过，无交付压缩包。[发行清单证据](evidence/20261029-process-match-fix-full-v12/release-verification.json)。

用户在服务器从托盘退出两端并停止后台后，以原账号覆盖安装 v12，选择一次性工程重建。无需卸载旧版、手动改工程所有者或删除备份。成功后继续从保留的 MQTT 数据源扫描添加变量，再导入工艺画面匹配。
