# v84 · 物料管理、统一分页与总览显示

2026-11-13，本地 Windows/Web/APK 交付。产品源码提交 `faa9b8e18c5938c4dd84733059354326882760f1`；构建源码 SHA256 `3d3fe99f256eb1c402640f7d37e22373ede037b740290b105dc750c12b0bebaa`。本记录说明已交付范围及验收边界，业务合同仍见[实施记录](material-management-implementation.md)，活跃状态只见[看板](../../AI_BOARD.md)。未部署现场或修改 18153。

## 本次结果

- 桌面物料管理包含申请与审批、品类管理、入库管理、库存管理、出库管理、操作日志六页。进入和切换自动查询；审批状态用颜色、图标和文字区分；复用可收起的模块侧栏。
- 操作日志按实际业务链及节点展示，支持业务类别、物料分类及子类筛选；权限投影、原单查看和必要摘要保持。申请审批到分批入库、出库到分批退库有明确链路；独立入库和转类不伪造批次来源。
- 当前个人签名只在本人账号安全页管理，可创建、更新、删除并保留版本。业务页只提供链接；审批、出库及退库使用确认时的签名快照。旧单据金额、名称、分类和签名不随资料变化而漂移。
- 支持原出库人分批退库、部分库存转类、完整分类路径；出库 Excel 调整为 A4 纵向、一页宽、小签名和长文本续行。
- 全系统已有分页列表使用数字页码、省略号、输入跳转。保留真实总数与原始历史 offset 上限；访问记录仅对已加载记录分页。桌面通常为 34px，手机为 44px；账号安全域访问记录沿用该页 44px 控件尺寸。
- Web/Windows 总览默认隐藏泵出口压力、补水泵电流、循环泵电流，可在开发端“运行与历史 → 数据总览配置 → 指标列”恢复。剩余列自动分宽；删除指标需确认，隐藏不清除绑定。手机忽略桌面显隐，首次进入显示全部指标，不沿用旧 APK 的分组筛选；桌面仍恢复原分组偏好。
- 按用户最后决定，手机本期不开放物料管理及相关个人签名入口；深链回总览，后端权限与桌面功能保留。APK 必须更新到本版，才能使用新的内嵌页面。

## 实际验证

| 项目 | 结果与证据范围 |
| --- | --- |
| Go | 最终 `go test ./...`、`go vet ./...` 通过；当前源码远端 Linux/Windows/macOS 后端任务通过，含 race 门禁 |
| Flutter | 最终 analyze 无问题，749 项通过，2 项既有跳过；额外 16 项实际 46 列配置、双泵、FE201/FE202、手机尺寸及显隐专项通过 |
| 事务与恢复 | SQLite/PostgreSQL 流程、独立连接并发、原子回滚、幂等重试、金额/行数/附件边界、历史签名与分类快照通过；15 张物料表 SQLite 备份及 PostgreSQL 18.6 dump/restore 逐行与资产字节核对通过 |
| 权限与通道 | 五种 TLS/WAF 认证通道及材料权限/签名历史范围通过；KP 是服务端关联会话测试，不是真实厂商宿主联调 |
| 实际业务页面 | 正常身份登录 Chrome；最终六页实际加载截图通过。出库 5×12.5=62.50，退 2 至废品、退 3 至正常，转类 4，最终正常 9/废品 6；原单金额不变，Excel 实际下载。业务办理证据在最终显示追加前完成，最终六页已复查 |
| 分页 | 614 条隔离申请，实际点击第 13 页请求 offset=600，输入第 7 页请求 offset=300，筛选后回第 1 页 |
| 最终总览 | Chrome 实际默认 3/6 指标、恢复压力列保存后 4/6 指标；手机保持 6/6。隐藏/恢复保存和双设备绑定保留另有 widget/API 回归 |
| 手机入口 | Chrome Android UA、APK client 入口、更多菜单，以及 iPhone UA+platform 模拟均验证物料隐藏、深链回总览、账号签名隐藏；这些是模拟视口，不是真机或 Safari 引擎 |
| Android | release 单测、Lint、assembleRelease 通过；版本 84，5,743 个 APK 内嵌资源逐一对比最终 Web，固定地址/证书保持，同签名验证通过 |
| Windows 安装 | v83→早期 v84 候选、候选覆盖/重装/卸载保留 5019 变量、31 图、12 张原有数据表及账号、设备、证书、图片、配置。最终总览/手机调整后的 r4 安装包完成同源及字节验证，未再次跑完整安装矩阵 |

安装矩阵第一次严格审计摘要不一致，定位为基线创建后的一条验收登录记录；原 3690 行摘要不变，仅增加该条正常登录审计。修正测试基线后严格复验通过，未放宽断言。

晚期全量测试曾在设备证书重新批准请求出现一次 `public_waf_denied`；随后 13 轮、65 个通道以及最终完整 Go 测试通过，并增加失败时只记录规则编号的诊断。尚未确定偶发误拦根因，不把重跑通过表述为已修复该既有问题。

## 交付与限制

下载目录：`D:/Users/SunYufei/Downloads/物料管理与总览_v84_20261113`，含独立完整 EXE、APK、使用说明、验收记录、截图、出库 Excel 隔离样例及 SHA256，无 ZIP。Windows 安装器未签名，WebView2 仍为原有外部前置；不改变现场升级流程。旧快照恢复会丢失快照之后的业务，程序降级不等于数据回滚。

| 文件 | SHA256 |
| --- | --- |
| Universal-HMI-20261113-Full-v84-Setup.exe | `eb90e06313e0aa04933bc5d11211a011dcb4ee93e55a561cf7da337255c8a23a` |
| Universal-HMI-Android-v84.apk | `b962dd337e4fbadb097329ce395b778e236e392529794dabeb352f769ba66b55` |

APK 签名证书 SHA256：`97247b52d1b26718619999c4c7fd4b308b8f50418079b954ba1e6faa132cf80c`，与前版一致。

未执行：本轮 Windows 原生文件对话框/DPI、人机现场验收、真实 KingPortal 宿主、Android/iOS 真机及真实 Safari。手机物料业务为用户明确延期，相关拍照/文件回调现场验收随开放另行安排。

产品提交的 [Verify 43406651117](https://github.com/YufeiSun5/universal-hmi/actions/runs/43406651117) 核对时后端三端及 Android 已通过，Flutter Web 已通过，其余三端仍在运行；[生命周期 43406651107](https://github.com/YufeiSun5/universal-hmi/actions/runs/43406651107) 已通过。不把旧提交或本地结果代替未完成的远端任务。

## 截图与原始记录

原始结果：[发布摘要](evidence/20261113-materials-v84/release-result.json)、[CI 核对](evidence/20261113-materials-v84/ci-summary.json)、[SQLite 恢复](evidence/20261113-materials-v84/sqlite-restore-result.json)、[PostgreSQL 恢复](evidence/20261113-materials-v84/materials-pg-restore-result.json)。该目录另存本次测试日志及下面截图，不含账号凭据、私钥或业务数据库。

| 观察点 | 截图 |
| --- | --- |
| 六页与共享侧栏 | [申请](evidence/20261113-materials-v84/v84-final-applications-desktop.png)、[品类](evidence/20261113-materials-v84/v84-final-catalog-desktop.png)、[入库](evidence/20261113-materials-v84/v84-final-inbound-desktop.png)、[库存](evidence/20261113-materials-v84/v84-final-stock-desktop.png)、[出库](evidence/20261113-materials-v84/v84-final-outbound-desktop.png)、[操作日志](evidence/20261113-materials-v84/v84-final-chains-desktop.png) |
| 出库及两次退库 | [确认](evidence/20261113-materials-v84/v84-step-outbound-confirm.png)、[部分退库](evidence/20261113-materials-v84/v84-step-partial-return.png)、[全部退库](evidence/20261113-materials-v84/v84-step-full-return.png)、[最终余额](evidence/20261113-materials-v84/v84-step-stock-balanced.png)、[链路](evidence/20261113-materials-v84/v84-step-outbound-chain.png) |
| 个人签名 | [本人管理与版本](evidence/20261113-materials-v84/v84-account-signature-desktop.png) |
| 真正跨页与筛选复位 | [第13页](evidence/20261113-materials-v84/v84-pagination-page13.png)、[筛选复位](evidence/20261113-materials-v84/v84-pagination-filtered.png) |
| 桌面显隐及分宽 | [默认](evidence/20261113-materials-v84/v84-overview-default-desktop.png)、[配置](evidence/20261113-materials-v84/v84-overview-column-editor.png)、[恢复后](evidence/20261113-materials-v84/v84-overview-restored-desktop.png) |
| 手机范围（Chrome 模拟） | [APK入口](evidence/20261113-materials-v84/v84-apk-entry-simulation.png)、[更多菜单](evidence/20261113-materials-v84/v84-apk-more-hidden.png)、[手机账号](evidence/20261113-materials-v84/v84-phone-account.png)、[iPhone平台模拟](evidence/20261113-materials-v84/v84-ios-platform-simulation.png) |
