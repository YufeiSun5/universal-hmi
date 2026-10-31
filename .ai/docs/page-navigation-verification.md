# 页面导航与 GIS 跳转验证 · 2026-10-27

后续更新：用户明确授权将原18153升级并保留工程后，部署已完成。当前PID43952，使用最终server-navigation.exe及web-navigation-20261027，数据目录仍为.local/gis-editor-preview/data。3份原JSON（点位及两张画面）SHA256均一致，SQLite逻辑内容摘要一致、完整性ok；备份位于.local/gis-binding-preview/backups/20261027-093038-navigation。菜单保持原工程默认disabled，不灌入隔离测试菜单。固定评审入口恢复为18153，原用户页未刷新。[部署核对](evidence/20261027-page-navigation/deployment-18153.json)。独立Chrome在18153实际打开新版[菜单配置](evidence/20261027-page-navigation/stable-18153-menu.png)，显示原公共地图与工艺画面，取消后再次核对JSON/SQLite未变。验证浏览器及18156/18157临时导航服务已关闭。下文18153被拦截的段落仅为前一轮历史记录。

本轮实现用户要求的通用菜单分组及 GIS 站标跳转。产品要求见[agent.md](../../agent.md)，唯一技术合同见[架构](architecture.md)。菜单组织不改变站点、变量或历史归属。

## 完成范围

- 开发资源管理器的「页面导航配置」可添加分组/画面、选择上级、跨站选择画面、重命名、同级排序，显式保存并检查 revision。最多4层、256项。
- 客户菜单点击组名展开并打开按配置顺序找到的第一张有效画面；重复点击回首图，独立箭头仅折叠/展开。支持搜索及祖先高亮；空组和失效目标可见。未启用自定义菜单时按现有画面归属生成菜单。
- GIS 站点编辑框可选择或解除「点击图标跳转到工艺画面」，随地图显式保存。客户点击进入目标实际归属站点；开发预览用只读弹窗。编辑态保留拖动，悬浮概况保持。
- 新增 GET/PUT `/api/v1/navigation` 和 MCP `navigation_get/navigation_save`；GIS 使用可选稳定 `target_screen_id`。后端校验存在性/类型，跨模块只调用公开服务。

## 自动检查：passed

- Go 1.24.7：全模块 test/vet 通过；最终 MCP 四层 schema 修正后 server/navigation 回归及全模块 vet 再通过。覆盖持久化、并发版本、超限/重复节点/目标校验、HTTP/MCP一致性、跨站 GIS 目标及目标删除。
- Flutter 3.35.4：analyze 与全量168项通过；最终编辑器草稿/辅助函数修改后 analyze 与16项相关回归通过。覆盖组名/箭头行为、首个有效目标、跨站/失效目标、编辑草稿隔离、排序保存和 GIS 跳转解析。
- Windows/Web release 通过，最终源码摘要 `0b9467e2918c2383524962350d89d76e92a76fa5c37c7f3f56ebf7324900624d`。保留现有 Nuget/CMake 及 Cupertino 字体提示；未将提示隐藏或当作功能通过依据。
- [Go日志](evidence/20261027-page-navigation/go-test.log)、[最终Go回归](evidence/20261027-page-navigation/final-go-test.log)、[Flutter全测](evidence/20261027-page-navigation/flutter-test.log)、[analyze](evidence/20261027-page-navigation/analyze.log)、[Windows构建](evidence/20261027-page-navigation/windows-build.log)、[Web构建](evidence/20261027-page-navigation/web-build.log)。

## 真实浏览器：passed

隔离服务18156、独立空点位工程，两个独立站分别保存 nav-a/nav-b，公共地图 nav-map；分组包含两站画面及一个空组。测试未接入现场设备或来源。

1. 关闭 Flutter 语义覆盖层，以真实鼠标点击组名打开甲站、点击子项打开乙站、独立箭头折叠、再次点击组名回甲站；对应请求目标与选中高亮一致。
2. 编辑器中上移乙站并保存，GET结果为 revision 2、乙站在前。640×300窗口中内容可滚动、底部操作可见，取消可点击。
3. 从 GIS 站点编辑框搜索并选择乙站画面，确认后拖动站标，再保存地图。地图 revision 2、坐标改变且 target_screen_id 仍为 nav-b。
4. 客户 GIS 点击「独立甲站」图标后 GET nav-b 返回200，地图离开并渲染乙站工艺图，菜单高亮乙站；控制台0 error/0 warning。
5. 最终二进制另启18157独立演示工程，复制测试画面并通过新API保存同一菜单；健康检查及菜单读取通过，Web与最终构建摘要一致。

截图：[菜单运行](evidence/20261027-page-navigation/runtime-menu.png)、[点击父组](evidence/20261027-page-navigation/parent-first.png)、[箭头折叠](evidence/20261027-page-navigation/collapsed.png)、[配置编辑器](evidence/20261027-page-navigation/editor.png)、[小窗口](evidence/20261027-page-navigation/editor-small.png)、[GIS目标配置](evidence/20261027-page-navigation/gis-target.png)、[点击后工艺画面](evidence/20261027-page-navigation/gis-jump-final.png)。[保存后HTTP结果](evidence/20261027-page-navigation/isolated-result.json)、[最终预览](evidence/20261027-page-navigation/preview.json)。

## 交付及未执行项

本轮代码与构建完成，独立评审入口为 <http://127.0.0.1:18157/?view=process>、`?view=gis` 和 `?view=development`，数据均为本轮隔离示例。

18153服务替换命令被自动审批拒绝，工具仅返回“blocked by policy”，整条命令未执行。18153仍为此前版本，用户原浏览器未刷新、原工程未写入新菜单或跳转配置。未将独立演示描述为原预览已升级。

本轮没有重打安装包；Windows构建不替代本次原生鼠标跳转验收。真实站址/点位及用户视觉评审仍待后续。收尾核对当前远端[完整CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/38031925059)及[生命周期CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/38031925060)均为success，head为f552d81；这些旧CI不覆盖本轮未提交工作树。7份相关文档相对链接检查及本轮相关路径diff空白检查通过。PROJECT-01原有open范围与PROCESS-01评审状态保持。
