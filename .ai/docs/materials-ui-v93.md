# v93 · 物料管理六页界面审查与整改

2026-11-16。用户要求以修改前端为主，审查全部物料页面及关联弹窗。本轮复用 Flutter Material、现有分类树、日期选择器、权限接口和文件预览，无新增组件库或存储服务。

## 六页结果

| 页面 | 本轮检查及整改 |
| --- | --- |
| 申请与审批 | 列表优先申请内容；详情内容与状态突出，审批/驳回明确分开；短内容弹窗自然高度，历史可展开；申请选择保留最近7天倒序、日期范围及仅未入库。 |
| 品类管理 | 物料名称优先；分类树搜索、层级、路径、分页及删除/恢复入口沿用；弹窗统一控件尺寸，窄窗口工具栏显示滚动条。 |
| 入库管理 | 统一关联申请、物料白色卡片、分类更改、数量/价格和底部主操作；选料支持独立分类树及规格/单位/参考价格；凭证缩略图可放大。 |
| 库存管理 | 强调物料与当前库存；详情突出数量/金额，保持后端快照；转移/确认沿用共同表单和样式，不重算库存。 |
| 出库管理 | 分类树选料展示价格及可用库存，零库存禁用；确认突出数量/金额；详情突出剩余可退数量，导出与办理退库放在金额之后，签名缩小。 |
| 操作日志 | 列表内容优先、详情入口明确；链路节点标题与金额加大，打开原单使用有边界按钮；保持汇总权限边界。 |

桌面表格主信息15px，辅助信息13px；窄窗口改为内容优先卡片。详情名称19px、数量/行金额22px、合计24px；主操作44px，常规弹窗按钮40px。使用工作台原有浅色、灰蓝色及字体，主题仅作用于物料弹窗。

## 交互修复与边界

- 关联单据在当前详情窗口内切换并可返回；当前单库存流水标识为“本单流水”，不再打开自己；快速返回时丢弃旧响应，切换后滚动复位。加载失败可重试或返回。
- 已保留草稿在会话内切页不重复弹离开确认；退出/登出仍由主壳保护。未决操作ID保持，不能把离开当作提交成功。
- 入库/出库选择器的分类状态独立，不改变主页面筛选；沿用API分页、搜索与分类过滤。缺价与零价格区分，不将缺价算成零。
- 后端唯一业务调整为本人申请审批：必须同时拥有当前申请与审批权限；审批他人仍按审批权限。签名、版本、幂等、审批历史均保留。SQLite/PostgreSQL和五种真实认证通道有回归。
- v92远端macOS工程归档测试失败源于临时父目录的系统符号链接；本轮只修测试fixture路径解析，与已有fixture保持一致，没有放松正式工程路径安全校验。

## 验证记录

最终本地验收完成，源码 b292c10c。Flutter analyze无问题，完整测试795项通过、2项既有跳过；物料截图/交互专项49项通过；Go全test/vet及SQLite/PostgreSQL自审矩阵通过。Windows/Web构建及包内源文件清单、后端与Web字节摘要一致，完整安装包SHA256核对通过。截图均为实际Flutter组件渲染，使用隔离合成fixture，不代表真实用户业务或浏览器/原生部署验收。

已执行物料专项49项，包含两种窗口尺寸、六页截图、分类选择、零库存、价格、审批权限、连续关联跳转、失败重试、迟到响应、草稿保持以及提交幂等。Go全量test/vet和SQLite/PostgreSQL自审矩阵已通过，Flutter analyze无问题。

额外开启全项目可选截图测试时，非物料站区总览在1180宽出现1.9px纵向溢出（workbench_visual_test.dart的reference-overview-1180）；本轮未修改该模块，未认定修复。物料截图专项未发生布局溢出。常规完整测试与可选截图测试结果分列，不以关闭截图掩盖该发现。

本轮未部署现场/18153，未重新执行完整安装/回退矩阵、真实浏览器点击、原生DPI和Android真机验收。沿用v92文件存储：升级前备份完整工程，必须包含数据库和objects/equipment/photos；回退旧版恢复完整旧备份。

## 交付证据

[摘要](evidence/20261116-materials-ui-v93/release-result.json)、[完整Flutter回归](evidence/20261116-materials-ui-v93/flutter-test-final.log)、[物料专项](evidence/20261116-materials-ui-v93/all-material-ui.log)、[构建](evidence/20261116-materials-ui-v93/build.log)。

[申请详情](evidence/20261116-materials-ui-v93/application-1280.png)、[入库办理](evidence/20261116-materials-ui-v93/editor-inbound-1440.png)、[分类选料与价格库存](evidence/20261116-materials-ui-v93/picker-outbound-1440.png)、[出库详情](evidence/20261116-materials-ui-v93/detail-outbound-1440.png)。

源码已推送并核对远端SHA，草稿[PR #68](https://github.com/YufeiSun5/universal-hmi/pull/68)以v92为基底，尚未合并。远端CI仍独立核对，不能将本地测试当成远端通过；见[同步状态](evidence/20261116-materials-ui-v93/remote-status.json)。可选非物料截图失败见[原始异常](evidence/20261116-materials-ui-v93/optional-workbench-screenshot-failure.txt)。

六页截图：[申请与审批](evidence/20261116-materials-ui-v93/page-applications-1440.png)、[品类物料档案](evidence/20261116-materials-ui-v93/page-items-1440.png)、[入库管理](evidence/20261116-materials-ui-v93/page-inbound-1440.png)、[库存管理](evidence/20261116-materials-ui-v93/page-stock-1440.png)、[出库管理](evidence/20261116-materials-ui-v93/page-outbound-1440.png)、[操作日志](evidence/20261116-materials-ui-v93/page-chains-1440.png)。
