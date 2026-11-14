# v91 · 入库关联申请选择

2026-11-15根据用户截图修正“新建入库”中不明显的申请关联按钮，并补齐选择弹窗日期、默认最近7天倒序及未入库筛选。源码2a9651c1，基于v90，包含此前功能。Windows/Web同源完整安装包及最终截图已交付。

## 使用

“新建入库 → 关联采购申请（选填） → 选择已批准申请”。入口采用带图标的明确操作按钮，关联后显示完整单号/内容，并可更换或取消关联；无关联时仍为独立入库。

弹窗默认显示北京时间含今天在内最近7个自然日提交的已批准申请，按提交时间从新到旧排列；每条显示提交时间。开始/结束日期可通过中文日历修改，日期和筛选改变自动查询并回到第一页；支持“最近7天”“全部日期”和关键词。

“仅未入库”指没有任何关联入库单。只要已办理过一次入库，包括分批入库，该申请即不出现在此筛选结果；取消勾选后可继续选择它办理下一批。不新增“全部入库完成”的状态，也不推断文字需求数量。选中关联保存原申请ID/版本，正式入库仍沿用后端状态和版本检查。

## 实现和验证

- Flutter仅修改物料编辑器/记录选择器。其他物料、分类选择弹窗不增加申请条件；查询失败清掉旧结果，防止误选上一次筛选的记录。
- 现有GET applications增加可选inbound_status=none，需要入库权限；使用现有单据关联和索引做NOT EXISTS查询，不改历史数据或库存事务。默认列表、批准权限、分批入库行为保持。
- SQLite及隔离PostgreSQL测试通过日期包含起点/排除终点、批准状态、时间倒序、分页总数、独立入库不误排除、部分入库排除及权限/无效参数拒绝。HTTP参数传递及权限回归通过。
- Go完整test/vet通过；Flutter analyze无问题、771项通过/2项既有跳过，最后中文日历/按钮调整后33项相关测试通过。涵盖默认北京时间范围、日历输入、搜索和未入库条件保持、分页重置、失败不选旧记录、选中ID/版本和取消关联。
- 隔离正常TLS/MFA接口实测4张已批准申请、仅未入库2张，提交时间倒序，已有部分入库单正确排除。实际Chrome最终资源的按钮、日期日历/输入模式、筛选、1093×614窄窗、选中和取消关联通过；控制台0错误/0警告。测试后端及Web关键文件与打包内容逐项哈希一致。

不部署现场/18153，不改现场工程或历史单据。本轮不重跑完整安装覆盖/卸载矩阵、原生DPI/IME、真实KP或手机真机；手机物料仍按既有产品范围隐藏，本次交付Windows/Web完整EXE。

前置v90最新远端CI43596490241/43596490287成功；本版远端状态另行记录，旧版成功不代替本版验收。

## 交付证据

完整安装包：Universal-HMI-20261115-Full-v91-Setup.exe，285,024,108字节。SHA256：`b98322eab878e5b435fdbafbf1fd695b7ad4cad805e86425864c65feedc6448c`。Windows/Web源摘要：`7b8e80fc076601a73f464322e07d5f8adc5f5ee15bb7da518b76a4758473484f`。

本地交付目录：`D:/Users/SunYufei/Downloads/入库申请选择_v91_20261115`，包含独立EXE、使用说明、校验值、验收记录及截图，无ZIP。隔离服务与浏览器已关闭。

远端源码2a9651c1生命周期CI成功；跨平台流水线记录时仍在运行，不代表全平台已通过，PR #66保持草稿。

- [go-test.log](evidence/20261115-materials-v91/go-test.log)
- [go-vet.log](evidence/20261115-materials-v91/go-vet.log)
- [go-http.log](evidence/20261115-materials-v91/go-http.log)
- [postgres-ux.log](evidence/20261115-materials-v91/postgres-ux.log)
- [analyze.log](evidence/20261115-materials-v91/analyze.log)
- [flutter-test.log](evidence/20261115-materials-v91/flutter-test.log)
- [targeted.log](evidence/20261115-materials-v91/targeted.log)
- [build.log](evidence/20261115-materials-v91/build.log)
- [api-result.json](evidence/20261115-materials-v91/api-result.json)
- [browser-result.json](evidence/20261115-materials-v91/browser-result.json)
- [release-result.json](evidence/20261115-materials-v91/release-result.json)
- [ci-summary.json](evidence/20261115-materials-v91/ci-summary.json)
- [v91-inbound-button.png](evidence/20261115-materials-v91/v91-inbound-button.png)
- [v91-picker-default.png](evidence/20261115-materials-v91/v91-picker-default.png)
- [v91-picker-unreceived.png](evidence/20261115-materials-v91/v91-picker-unreceived.png)
- [v91-picker-1093.png](evidence/20261115-materials-v91/v91-picker-1093.png)
- [v91-calendar.png](evidence/20261115-materials-v91/v91-calendar.png)
- [v91-calendar-input.png](evidence/20261115-materials-v91/v91-calendar-input.png)
- [v91-linked-application.png](evidence/20261115-materials-v91/v91-linked-application.png)
- [v91-link-cleared.png](evidence/20261115-materials-v91/v91-link-cleared.png)
