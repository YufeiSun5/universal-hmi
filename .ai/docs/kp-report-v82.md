# KP总统计报表入口修复 v82

2026-11-13。产品母本为[agent.md](../../agent.md)，边界见[架构合同](architecture.md)。

## 问题及修复

KP壳使用 `/kp/` 基地址，报表iframe解析为 `/kp/total-reports/`。原公共路径边界只允许普通Web的 `/total-reports/`，因此合法KP入口返回`public_path_denied` 403；即使仅放开这一条，KP静态文件层仍拒绝目录。

修复只允许明确的KP报表入口；直接提供固定index.html，显式index.html也不重定向。子资源沿用KP静态路径，任意目录、缺失原稿目录列表、重复分隔符、路径穿越和编码分隔符仍不允许。GET/HEAD可读取公开静态组件；业务数据通过认证的父页面桥接，不在HTML中包含数据或凭据。

同时补齐两个关联缺口：旧KP报表链接的同源parentOrigin按已有普通Web规则兼容，其他查询参数/异源和重复parentOrigin保持WAF检查；将history-state列入明确的公共只读路由，保持KP有效会话和报表读取权限，避免页面打开后加载/未结算状态仍遭拒绝。配置、模板导入及现场控制等开发/写入权限未扩大。

用户截图的`GET /static`为审计固定分类，不能据此恢复现场完整URL。已在隔离环境按真实前端生成路径复现同样错误并修复；截图另外的401和事件访问资格失效属于认证/撤销记录，本批未将失效会话放行或宣称现场认证问题全部解决。

## 验证

- 修复前独立用例准确复现`GET /kp/total-reports/`返回403及`公网路径格式不受支持`。
- 修复后目录/显式index入口、GET/HEAD、相对JS资源、CSP与no-store通过；无重定向，缺失index返回404，任意目录、穿越和未认证API仍拒绝。
- 正式main隔离HTTPS/WAF启动：无普通Web IP批准也可读取KP报表静态资源；经可信上游fixture核验、兑换KP身份后，携带旧普通Web Cookie读取目录、报表实例和history-state成功。KP关闭后同接口拒绝；普通Web不能绕过IP准入。
- WAF旧同源KP链接通过；异源、重复字段及其他注入参数仍拒绝。

本批不改Flutter或报表前端源码；沿用v81界面与报表行为。Go完整测试/vet、Windows/Web同源构建和独立EXE校验通过。未部署现场/18153，不将隔离测试冒称真实KP现场验收；未重跑安装覆盖/重装/卸载矩阵或原生IME/DPI。

## 交付

源码`74145feb`，Windows/Web源文件及输出清单一致。完整EXE版本`0.1.0.82`，文件名`Universal-HMI-20261113-Full-v82-Setup.exe`；位于Downloads的`KP报表修复_v82_20261113`目录，附简短说明及SHA256，无ZIP。包含v81界面/文案、00:00和当前日表底/加载提示。

[交付摘要](evidence/20261113-kp-report-v82/delivery.json) · [修复前](evidence/20261113-kp-report-v82/red.log) · [修复后专项](evidence/20261113-kp-report-v82/green.log) · [HTTPS/WAF整链路](evidence/20261113-kp-report-v82/https-integration.log) · [Go结果](evidence/20261113-kp-report-v82/go-result.json) · [CI快照](evidence/20261113-kp-report-v82/ci.json)。

隔离main测试通过自动清理临时工程与进程，不改现场。交付时远端跨平台CI仍在运行；不宣称全部平台门禁通过或合入main。现场更新后台后重新打开KP复核，无须重导报表或放宽白名单。
