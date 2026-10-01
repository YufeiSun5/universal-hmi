# 当前上下文

更新：2026-10-01。产品母本 agent.md，唯一活跃看板 AI_BOARD.md。

用户授权直接实施第一版完整功能与 UI，Linux 优先，完成可运行版本后评审。会话执行环境启动失败；所有编译、实际 Linux 原生操作、浏览器文件操作和本地 MQTT 流程在 GitHub Actions 虚拟机执行，不能说是在会话容器完成。

第一版核心已通过 [CI 36801113430](https://github.com/YufeiSun5/universal-hmi/actions/runs/36801113430) 六项验证：Linux/Windows Go 测试及构建、Flutter Web/Linux/Windows 分析测试及构建、完整桌面加 Web 打包。Linux 原生测试覆盖添加→保存草稿→显式应用→真实后端采样→快照→历史→导出；Chromium 覆盖文件选择→映射→导入→数值筛选→统计→XLSX 下载并重读；Mosquitto 流程覆盖 10 站拆包、换算、虚拟点、坏质量、AND 持续条件、多动作、独立历史、generic 下设及命令去重。Windows 实机人工交互尚未执行。

当前收尾提交保存 CI 生成的格式化源码、真实锁文件和 Linux runner，修正工具栏对齐、历史目录计数、模拟设定值新鲜度，改善实际截图并补验最终打包后的自动启动和 Web 资源。此批新增验证结果待 CI；不把已通过上一批扩大为新提交通过。

SPT 通用能力是审阅参考，本批没有复制其检测业务或声称 Lite 源码已迁入。来源保存后显式连接；Kepware/KingIO 只做已声明读协议；物理写仅 generic 命令，sent 是 broker 收到，不是 PLC 应答。重启事件禁用，未知写不重放。独立存储不依赖检测或 UI。
