# 初始化记录

日期：2026-09-30。用户明确授权创建 public 项目并按其提示词工程初始化，随后授权实施可编译工程骨架。

来源：dotai-scaffold/prompt-zh.txt，blob d34a84e7ad485c726274a92c9f798c3bdf61a886。未机械复制全目录；采用产品母本、工具入口、当前上下文、唯一看板、架构母本和必要约束。

产品母本为根 agent.md；AGENTS.md 仅引用入口，以适配实际编码工具。架构母本包含模块/层职责、计划路径、公开接口、依赖/禁止项、数据所有权、验证方法和两条核心流程。PC/Web、Flutter 体验、点位添加、存储、图表、Excel 分析/筛选/导出及条件事件均已记录。

不迁入 SPT 检测专用业务；独立存储具体来源待定位。应用初始化与 SPT 迁移分别记录。当前执行环境离线，不伪造本机/虚拟环境构建通过；仓库 CI 结果另附证据。

文档初始化已提交于 57ef20f9ad6eacf712d5e4a951ddddb9c3514142（README 初始提交 9e911f29756d857a878027eee5c24b546722ad84）。初始化文档内部链接检查：24 项通过，无缺失。

第一轮编译：源提交 e55e7aa89be6864cf95e5903299982a3cbed1deb，[CI 36757831630](https://github.com/YufeiSun5/universal-hmi/actions/runs/36757831630) 全部 success：Linux Go 测试/vet/build；Flutter Web 与 Windows analyze、2 项 widget 测试、Release build。Web 和 Windows 产物均上传。

平台初始化来源：[Bootstrap CI 36758600481](https://github.com/YufeiSun5/universal-hmi/actions/runs/36758600481)，分支 bootstrap-native，提交 21c5ad7f2d783f85739719de16ef4ec48e92251f。Windows Go test/vet/build 成功；固定 Flutter 3.35.4 生成标准 Web/Windows runner，pub get 生成锁文件，gofmt 格式化源文件。仅导出公开代码/模板，不包含环境变量或凭据。回填标准文件后最终提交将再次按锁文件直接构建。
