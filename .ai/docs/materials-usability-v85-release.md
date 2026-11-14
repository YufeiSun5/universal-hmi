# v85 · 物料易用性与统一账号首页

2026-11-14 本地 Windows/Web/APK 交付。承接[用户确认的改进计划](materials-usability-plan-20261113.md)，产品源码 `4a248b17e544fccc6b54ae5c6d9a5c86ec1c0416`，构建源码 SHA256 `0d2b45d905dc0ab72e964c7ae1574b6d8b35b250152095a893a631dd864fde93`。分层与接口合同见[架构](architecture.md)，活跃状态只维护[看板](../../AI_BOARD.md)。

## 已交付行为

- 品类默认展开，分支独立分页，保留会话内的手动收起/选择。分类搜索展示全路径；主列表刷新同时刷新分类树。分类删除采用可恢复状态，预检显示子类、档案和非零库存数量，提供查看依赖入口；正式提交事务内重查，保留版本及幂等约束，历史单据和签名保持。
- 物料左侧在业务菜单下增加分类树，父分类包括子类，切换业务页保留选择；纯申请/审批账号不读取物料目录或金额。档案/库存/入出库/操作日志复用分类条件。
- 入出库日期常驻，按北京时间生成起点包含、终点排除的范围。概览统计全部有权匹配行，分页不改变总数；数量按单位分开、缺价单独提示、金额沿冻结快照。分类部分命中时区分分类小计与整单金额。本期发生退库按实际退库时间和目标分类单列，可包含往期出库。
- 本人账号安全中设置一个跨终端首页，有权明确链接优先；手机不支持物料时临时回退且保留原设置。各运行入口和首页候选使用后端页面访问集合，无权入口隐藏，业务API授权保持；没有新增一级页面独立授权开关。旧服务器未声明新能力时保留原客户端入口逻辑。
- 物料表单增加步骤、必填/选填、单位/精度、库存变化、最大退库量和核对步骤。错误就地提示并可定位；明确失败允许修改，响应未知沿同一操作重试。草稿只保留当前登录会话。其他模块的完整表单引导改造不在本次范围。

## 实际验证

| 检查 | 结果与范围 |
| --- | --- |
| Go | `go test ./...`、`go vet ./...`通过；材料/偏好/页面权限/HTTP专项通过 |
| Flutter | analyze无问题；完整755项通过、2项既有跳过；后续分类刷新/依赖跳转/筛选标签调整完成最终33项专项通过，340文件格式检查通过 |
| SQLite / PostgreSQL | 分类删除与并发新建子类/入库采用独立数据库连接，恰一方成功；依赖阻止、恢复、重试、已删目标拒绝和旧出库合法退库通过。跨时区午夜、非法范围、子树/部分单据、混合单位/缺价、分页不变与跨期退库通过 |
| 权限 | 正常TLS/MFA登录的申请、入库、出库、档案、普通只读及工程师六类隔离账号；页面集合和直接API范围通过。入库账号按既有合同可读取已批准申请用于关联入库，不获得审批能力。四种物料专项账号实际浏览器菜单分别核对通过 |
| Chrome实际流程 | 分类必填报错、新建、删除、已删除查看/恢复；父类筛出两个子类，12个和15.5米分别汇总、已知97.50/缺价1行；出库超量13被阻止，修改为3后核对3×8.125=24.38并确认，部分退1到另一有效分类，原单累计退库/追溯保持 |
| 首页 | 实际保存出库首页及立即打开、重新加载进入出库；Android UA浏览器回退总览、账号页显示保留原首页。首页偏好不授予权限，过期revision拒绝、并发修改和原会话保持有单测及HTTP覆盖 |
| 布局 | 实际1366×768、1920×1080、1093×614可用视口，以及390×844手机截图。1093×614是1366尺寸下等效125%的可用空间，**不是Windows原生DPI验证**。单据表窄窗使用水平滚动 |
| 兼容与重启 | 复制v84隔离工程进入新版后，原14张业务表（不含写锁计数表）全部旧行逐行保持；最终包后台与Web重启后删除状态、账号首页及单据汇总保持。重启后用正常MFA重新登录，不把内存会话丢失当数据丢失 |
| 同源构建 | Windows/Web源码摘要一致，组包校验通过；完整安装器版本0.1.0.85，APK版本85。Android22项单测、Lint、release通过，5743个内嵌Web文件逐字对比，签名与前版相同 |

只在隔离工程办理业务，未部署现场、未修改18153。没有重跑完整安装/覆盖/卸载矩阵，未执行Windows原生DPI/文件操作、真实KP宿主或Android/iOS真机验收。原生/现场结果不由浏览器截图代替。v84记录的偶发证书审批WAF问题不在本批修复范围。

## 文件与远端状态

下载目录：`D:/Users/SunYufei/Downloads/物料易用性与账号首页_v85_20261114`。独立完整EXE、APK、使用说明、验收记录、截图和SHA256，无ZIP。

| 文件 | SHA256 |
| --- | --- |
| Universal-HMI-20261114-Full-v85-Setup.exe | `dae3870e34ef9245d18d3d709cf3962eb1bda29c97df4b67b5847554f348241a` |
| Universal-HMI-Android-v85.apk | `700ae0264650818f6788ff07c70d29515bcf04ec4219628c64ac26aa13f4b948` |

APK签名证书SHA256：`97247b52d1b26718619999c4c7fd4b308b8f50418079b954ba1e6faa132cf80c`。安装器未签名，沿用既有部署前置与保留数据策略。

产品提交[Verify 43453764507](https://github.com/YufeiSun5/universal-hmi/actions/runs/43453764507)首次后端Windows/Linux及Android成功；macOS测试/构建完成，随后GitHub ArtifactService连续5次创建产物超时，导致该job失败及Flutter/packages跳过。已重试失败job，交付核对时仍在途；不冒称远端全部通过。[Linux生命周期43453764557](https://github.com/YufeiSun5/universal-hmi/actions/runs/43453764557)通过。后续仅证据文档提交与本产品源码分别记录。

## 可复核证据

[发布摘要](evidence/20261114-materials-v85/release-result.json)、[权限矩阵](evidence/20261114-materials-v85/role-matrix.json)、[旧数据保持](evidence/20261114-materials-v85/migration-preservation.json)、[最终包重启](evidence/20261114-materials-v85/restart-result.json)、[APK核对](evidence/20261114-materials-v85/apk-verification.json)、[远端核对](evidence/20261114-materials-v85/ci-summary.json)。同目录保存实际测试日志；不含账号、口令、私钥或业务数据库。

截图：[分类汇总](evidence/20261114-materials-v85/v85-subtree-summary.png)、[删除阻止和跳转](evidence/20261114-materials-v85/v85-final-deletion-links.png)、[出库错误定位](evidence/20261114-materials-v85/v85-outbound-limit.png)、[退库引导](evidence/20261114-materials-v85/v85-return-guide.png)、[首页保存](evidence/20261114-materials-v85/v85-home-saved.png)、[手机保留首页](evidence/20261114-materials-v85/v85-mobile-home-preserved.png)、[最终出库](evidence/20261114-materials-v85/v85-final-outbound-1366.png)、[缩小可用窗口](evidence/20261114-materials-v85/v85-final-outbound-effective125.png)、[申请专权账号](evidence/20261114-materials-v85/v85-role-requester.png)。
