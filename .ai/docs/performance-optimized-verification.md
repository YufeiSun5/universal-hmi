# 5000变量优化与运行界面复核（2026-10-28）

本批按用户要求先后端、再前端订阅与视觉调整。技术合同见[架构](architecture.md#5000变量50会话优化2026-10-28)，当前任务见[看板](../../AI_BOARD.md)。不是现场或长期负载验收。

## 实现与验证

- Go：授权选择/增量SSE、128个新协议连接限额；多行事务、锁外有界周期历史队列；KingIO主动补全量及逐点接收确认。固定Go1.24.7全量`go test -mod=readonly ./...`、`go vet -mod=readonly ./...`通过，含真实PG集成；SQLite实际阻塞连接证明周期存储等待不占runtime锁，覆盖排队≠提交、超时重试、旧配置完成、队列限额、多块事务回滚/幂等。Windows未配race编译器，本批未执行race。
- Flutter：reset/delta合并、断序重连、按画面引用订阅及切页清值；工艺目录和标题蓝灰统一，GIS与浅色数据页保留。analyze及211项全量测试通过，Windows/Web release通过。仅构建不能替代原生鼠标/DPI验收。
- 浏览器：独立18158、隔离PG和EMQX，无用户数据写入。1440×900逐页检查工艺、GIS、设备台账、数据总览、报表、历史、外数据；760×520目录抽屉切高/低区、全部页面及台账通过。实际工艺网络请求27个ID，值持续更新；切图变为另一批引用，页面清除旧值。控制台error/warn为0。报表/历史为未筛选空态，外数据未配置空态，本轮不声称外库有数据展示已验。

## 短时容量结果

测试5000变量、50个独立账号及实际会话，每会话100点。每阶段约15秒（另有预热），MQTT每秒变化分别50/100/500/5000点，KingIO模拟每2秒响应全量查询；不是50个渲染浏览器。CPU为整机百分比，不是单核占用。

| 每秒变化点 | 连接成功 | SSE总Mbps | 后端整机CPU% | RSS峰MiB | 运行HTTP P95ms |
| --- | --- | --- | --- | --- | --- |
| 50 | 50/50 | 3.36 | 0.61 | 82.2 | 532 |
| 100 | 50/50 | 3.87 | 0.53 | 85.1 | 93 |
| 500 | 50/50 | 4.18 | 0.72 | 79.5 | 422 |
| 5000 | 50/50 | 9.42 | 0.92 | 87.8 | 78 |
| 5000 + 全库1秒存储 | 50/50 | 8.47 | 1.29 | 80.5 | 93 |

存储阶段测量窗口提交70000样本，全次累计100000样本实际PG行数一致；失败/拒绝/延后均0。累计接受/处理572295采集样本一致、drop0；首包源时间落后157秒仍可确认恒定值，漏回单点陈旧、坏质量、broker在线但停流、重连补全、账号撤销均通过。结果不能推算无限保留量、24小时负载或真实KingIO响应保证。

[原始结果](evidence/20261028-performance-optimized/results.json)、[阶段日志](evidence/20261028-performance-optimized/measure.log)、[补充日志](evidence/20261028-performance-optimized/measure-resume.log)、[脚本](evidence/20261028-performance-optimized/measure.py)。初次脚本撤销用户遗漏version获422，修正版本后独立补跑语义检查；阶段指标取初次原日志，合并结果标注来源，未修改产品校验或删除失败日志。

## 逐页截图与判断

[工艺调整前](evidence/20261028-performance-optimized/process-before.jpg)、[调整后](evidence/20261028-performance-optimized/process-after.jpg)：原白目录/浅标题夹在深色区域间，改为蓝灰目录、深蓝标题、青蓝选中，保留图纸内容。[小窗口目录](evidence/20261028-performance-optimized/process-compact.jpg)保留搜索、分组、切图。

[台账](evidence/20261028-performance-optimized/equipment.jpg)、[小窗口台账](evidence/20261028-performance-optimized/equipment-compact.jpg)：浅色档案区、汇总与列表层次保留，小窗口整体滚动。[数据总览](evidence/20261028-performance-optimized/overview.jpg)：矩阵有较高信息密度，保留既有矩阵/表格与密度切换，不用装饰卡片替代500点浏览。[报表](evidence/20261028-performance-optimized/reports.jpg)、[历史](evidence/20261028-performance-optimized/history.jpg)、[外数据](evidence/20261028-performance-optimized/external.jpg)：浅色筛选和内容区保持，真实空态不编造数据。[GIS](evidence/20261028-performance-optimized/gis.jpg)维持原地图、透明导航及站标。

## 发行与边界

固定18153已更新至 `dist/Universal-HMI-PerfOptimized-20261028`（PID75160）；运行/开发两个桌面入口共用原project.json。备份 `20261028-121817-performance-optimized` 含PG dump、工程目录及连接密钥，升级前后11张PG表数量和逻辑摘要一致，保留原1账号、4站点、3文档。静态JS与发行清单逐字匹配，服务健康、认证要求及本机5位口令策略正常；[部署记录](evidence/20261028-performance-optimized/deployment.json)保留实际结果。未刷新用户原浏览器、未带入隔离演示数据。

本批源码SHA256 `9ce6e1e37c486266b33923e94ddd69162ac2d7f9f12dc4ce853dc2aae1574476`，Windows/Web构建同源及完整包摘要核对通过；不新制安装EXE。2026-10-28再次读取远端，旧head f552d81 的38031925059/38031925060成功，仍不覆盖本工作树。构建中的既有Wasm/CMake/字体提示保留原日志，未冒称零警告。

后台Start-Process启动被自动审批拒绝，仅返回 `blocked by policy`；改用工具管理的前台进程后18153已就绪。桌面启动配置已指向新版本；本批没有额外启动原生窗口或验证关闭服务后的图标自动拉起。

规则动作仍同步存储；公共总览/开发页仍可订阅全授权目录。此次解决既定5000/50短测瓶颈，不宣布SCALE-01长期容量、AUTH-DEPLOY现场或UX-02原生人工已完成。现场真实查询周期和网关全量能力需操作方验证。
