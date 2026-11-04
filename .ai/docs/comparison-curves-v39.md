# v39 同期曲线、日期选择与北京时间

产品要求见 [agent.md](../../agent.md)，唯一看板见 [AI_BOARD.md](../../AI_BOARD.md)，契约见 [architecture.md](architecture.md)。2026-11-04开发，11月5日完成本地交付；构建版本保留v39及20261104标识。

同期对比通过既有连接和画面授权调用 `usp_气温水电热滑动对比`。先查汇总，按站展开气温、热、电、水四张曲线，支持小时/日期切换及联动游标。默认去年同期对齐，可按小时/天等长平移、一键恢复对齐；截至现在的查询冻结返回边界，明细使用同一窗口。原始十进制、有效零、NULL、配对覆盖和独立小计分别保留；缺失片段断线，日内缺失不冒称完整日。曲线不合并全站为全网总量。

用量差值采用数据库配对片段。天气、供热面积与运行条件尚未归一化，页面只报告实际用量变化，不把变化率标为节能率。天气校正基线模型本批尚未建立。

日期与时间字段提供日历及24小时钟面并保留键盘输入。业务输入、显示、曲线与新过程datetime2参数按北京时间UTC+8；报警确认人匹配移除旧Pacific假设。带UTC语义的既有接口字段继续按合同转换；未改写epoch/UTC历史数据，不能把本批描述为数据库时间迁移。

## 已执行

- Go 1.24.7全量 `go test -mod=readonly ./...`、`go vet -mod=readonly ./...`通过。
- Flutter 3.35.4完整回归576项通过，2项原浏览器专用跳过；最终analyze无问题，最终日期/对比专项4项通过。覆盖420px/1440px、迟到响应丢弃、有效零与NULL、日期日历/时间钟面和默认对齐。
- 实际SQL Server 2017隔离合成数据库及HTTP接口验证通过：08:15—12:30五片段×三指标、北京时间参数、decimal字符串、历史电NULL、新站、全站汇总、冻结边界、日缺失与加权气温。结果见[SQL证据](evidence/20261104-v39/sql-interface.json)。旧测试容器证书兼容仅作用于隔离进程，未改发行默认配置。
- 真实Chrome操作小时/日期、恢复同期对齐、日历和时钟，查看桌面/420px窄屏及缺数曲线；控制台无错误或警告。[小时曲线](evidence/20261104-v39/hourly-curves.jpg)、[窄屏](evidence/20261104-v39/narrow.jpg)、[日历](evidence/20261104-v39/calendar.jpg)、[时间](evidence/20261104-v39/time-picker.jpg)。图中为合成数据，不代表现场供热效果。
- 最终Windows/Web构建和包内逐文件身份通过，Android单元测试/lint通过；5740项APK资源和原签名、固定服务器身份一致。产品提交 `3eff4debfc23e7f5261d14f80482b28dbe5750f4`，源码SHA256 `46fe0738c516267e07aa30b2df9e9fe2db705ae84830e2d009a7363359e6928a`。
- 最终v38→v39隔离覆盖启动、原账号登录、同版重装、卸载保留通过：5019变量、31画面、11业务表、来源、绑定、导航及设备图片保持。应用/PostgreSQL摘要核对通过，隔离服务停止、安装登记清理、原快捷方式恢复。完整结果见[发行记录](evidence/20261104-v39/release.json)。

## 交付与边界

交付完整Windows EXE与同签名Android APK，不要求解压或重导工程。沿用安装身份及preserve-only升级策略，不执行工程reset。EXE仍未签名，WebView2沿用既有独立依赖。

[PR54](https://github.com/YufeiSun5/universal-hmi/pull/54)为草稿；产品head的[跨平台CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/41862179452)与[Linux生命周期CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/41862179464)在交付核对时排队，不能记为成功。最终文档head状态另计，未合并或部署。

用户提供的中心站21:10:20现场结果是已回传快照；本批未重新连接现场执行查询。新包现场接口/报警确认记录、安卓真机交互和Windows原生DPI人工复验待执行。本批未安装现场或修改18153工程。
