# v86 · 物料易用性改进最终本地交付

2026-11-14。包含[v85六项改进与验收](materials-usability-v85-release.md)，本次完成复核发现的提交成功引导缺口。源码 `75f8d01d0a6d9ebba3a4dc62ce07db8dc5eebb0d`；构建源码SHA256 `bddbdf0d2597c0a3c47962bffb5c567158f6caf0f130b41b9d0fb6fd251bad69`。

## 完成范围核对

| 用户要求 | 当前实现与直接证据 |
| --- | --- |
| 品类默认展开、搜索与删除/恢复 | v85分类树默认展开及51子节点分页widget、SQLite/PG独立连接竞争、真实Chrome删除/恢复/依赖阻止；历史金额和签名保持。v86未改这部分代码 |
| 左侧分类快速筛选 | 父类包含子类，切页保留条件；列表、库存和历史单据按正确分类匹配；v85子树汇总实操与SQLite/PG断言，纯申请账号目录API403 |
| 一个账号统一首页 | 服务端本人偏好、revision和持久化；v85保存/重新加载/立即打开及手机回退不覆盖截图；明确有权链接优先、无页回退账号页有单测 |
| 无权入口隐藏 | 后端页面集合驱动导航和首页候选；v85六角色正常TLS/MFA API矩阵和四角色Chrome菜单；不以界面隐藏代替后端授权 |
| 北京时间段查询与概览 | 默认本月、常驻日期和快捷范围；全匹配行汇总、按单位数量、缺价与分类小计、跨期退库；v85 SQLite/PG时间边界和分页回归、实际混合单位截图 |
| 填写、错误和成功后的引导 | v85步骤/标签/库存与退库限额/字段定位/未知结果原操作重试；v86增加保留单号与库存变化说明的成功对话框、查看单据、出库Excel导出及继续新建。新草稿不带上笔明细；导出失败不重复记账 |

本次修改仅位于Flutter物料展示/导出复用及Windows/APK版本号。Go业务、权限、数据库与分类/统计/首页实现未变。其他模块全面表单改造、现场部署不属于更新计划的本次实施范围。

## 本次验证

- Go `go test ./...`、`go vet ./...`通过；Flutter analyze无问题、完整759项通过/2项既有跳过；新增结果流程及现有物料25项专项通过。
- 新增widget验证：成功提示10秒后仍可操作；继续新建清空原明细且只提交一次；导出失败两次均只GET且保留已保存状态；1366×768/1.25像素比例下中文组合输入、Tab定位与回车提交通过。这是自动化布局/键盘验证，不声称Windows系统IME/DPI人工实测。
- 真实Chrome隔离TLS/MFA会话完成1个球阀出库，成功页显示单号及库存变化；1366×768和1093×614可用视口截图已检查；实际下载XLSX，核对单号、8.13金额和签名图片；继续新建为空白草稿。
- Windows/Web源码摘要一致，最终组包清单通过。最终包后台与Web重启后分类删除状态、统一首页、入出库汇总保持。
- Android22项单测、Lint、release通过；5743个内嵌Web文件逐字匹配，签名证书SHA256仍为 `97247b52d1b26718619999c4c7fd4b308b8f50418079b954ba1e6faa132cf80c`。

无现场/18153修改。完整安装覆盖/卸载矩阵、Windows原生DPI/系统IME、真实KP和手机真机不在本次新增验证范围；保留v85明确边界。安装器未签名，WebView2沿既有外部前置。

## 交付文件

下载目录：`D:/Users/SunYufei/Downloads/物料易用性与账号首页_v86_20261114`。独立完整EXE、同签名APK、说明、验收证据/截图和SHA256；无ZIP。v86包含v85，不需要先安装v85。

| 文件 | SHA256 |
| --- | --- |
| Universal-HMI-20261114-Full-v86-Setup.exe | `77f740edb2547cc2fe1cc02eb0d43a25b50aad5e759b76f20e2462f587c0e8af` |
| Universal-HMI-Android-v86.apk | `ce40a83f7ec9da0dbd0b759e065ef250de3718c5203ac736e53e8b7759ef5151` |

两端版本均为86，Windows文件资源版本0.1.0.86已读回核对。

## 远端检查与本地结果分列

[产品CI 43462985518](https://github.com/YufeiSun5/universal-hmi/actions/runs/43462985518)最后成功查询时Linux/Windows后端与Android通过，macOS在运行，后续Flutter/packages尚未完成；期间出现过GitHub TLS查询超时，未据此认定任务停止或重新启动。PR仍为draft，不声称跨平台PR检查全部通过或已合并。本地Windows/Web/APK测试和最终产物已独立通过。

## 证据

[发布摘要](evidence/20261114-materials-v86/release-result.json)、[浏览器与导出](evidence/20261114-materials-v86/browser-result.json)、[最终包重启](evidence/20261114-materials-v86/restart-result.json)、[APK核对](evidence/20261114-materials-v86/apk-verification.json)、[CI快照](evidence/20261114-materials-v86/ci-summary.json)。同目录保留Go、Flutter、Android及构建日志；不含测试口令或私钥。

截图：[成功操作区](evidence/20261114-materials-v86/v86-receipt-1366.png)、[缩小可用窗口](evidence/20261114-materials-v86/v86-receipt-effective125.png)、[继续新建](evidence/20261114-materials-v86/v86-fresh-draft.png)。
