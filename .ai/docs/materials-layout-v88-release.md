# v88 · 物料布局细化与领用方

2026-11-14按用户反馈实施。源码 `5da581d2ea36c1eb10f1a605c22ea793f5823b77`；Windows/Web构建源码摘要 `734c10dc2f8dd2b0e75aa7f19d4951971bbcf68421fc828d70457d75d2e2d3d1`。本地Windows/Web/APK交付完成。

菜单由248px收紧至144px，分类树保留120px；三列以8px间距、背景和细边框分隔。菜单收起后分类筛选仍可用。查询区按右侧实际宽度排布；表格为单号、领用方及明细分配更多空间，各列随窗口重新分配，极窄时展示完整字段记录卡片。仅修改物料模块，其他报表表格不变。

出库列表直接显示“领用方”，历史空值显示“未填写”。表单提示可填个人、班组或单位，单据详情、链路详情和Excel导出统一名称；仍使用原recipient字段，不修改历史数据、记账或权限规则。

## 验证

- Go完整 `go test -mod=readonly ./...`、`go vet -mod=readonly ./...`通过；Flutter analyze无问题，完整762项通过/2项既有跳过；变更范围16个Dart文件格式检查通过。
- widget真实数据回归覆盖1366→1920→1093→900→1366连续缩放，领用方及空值、右侧详情操作可见可点；原菜单独立树测试增加144/120/8px几何断言，收起和分类请求保持。
- 正常TLS/MFA身份进入隔离Chrome。六页面、四种视口、分类筛选、菜单收起、新建出库和原单详情共14张截图逐张检查（含最终包复验）；分类筛出3单、清除恢复6单，收起菜单保留树。实际下载Excel并读取确认“领用方：北站运行维护班组”；正常运行阶段控制台无错误或警告；计划停止隔离服务时产生3次断连/旧会话请求失败，重启后正常API登录并恢复页面。
- Windows/Web同源码构建和组包核对通过；完整EXE 0.1.0.88生成，Android22项单测/Lint通过、5743个内嵌Web文件逐字匹配且签名证书保持。最终包后端/静态资源重启，6张入库、6张出库、10行库存及所有返回业务行/汇总一致；实际浏览器重新加载最终包正常。
- 前版v87远端跨平台[43553495629](https://github.com/YufeiSun5/universal-hmi/actions/runs/43553495629)及生命周期43553495063最终成功。本版[43557721837](https://github.com/YufeiSun5/universal-hmi/actions/runs/43557721837)核对时Android已成功、三端Go在途；本版生命周期43557721797成功，远端跨平台尚未全部完成。

本轮未部署现场/18153，未重跑完整安装覆盖/重装/卸载矩阵、原生系统DPI/IME、真实KP或手机真机。缩小视口仅证明对应可用空间布局；手机物料继续按既有范围隐藏。

## 证据

[浏览器结果](evidence/20261114-materials-v88/browser-result.json)、[Go测试](evidence/20261114-materials-v88/go-test.log)、[Flutter测试](evidence/20261114-materials-v88/flutter-test.log)。

截图：[出库1366](evidence/20261114-materials-v88/v88-outbound-1366.png)、[1920](evidence/20261114-materials-v88/v88-outbound-1920.png)、[1093](evidence/20261114-materials-v88/v88-outbound-1093.png)、[900](evidence/20261114-materials-v88/v88-outbound-900.png)、[入库](evidence/20261114-materials-v88/v88-inbound-1366.png)、[申请](evidence/20261114-materials-v88/v88-applications-1366.png)、[品类](evidence/20261114-materials-v88/v88-categories-1366.png)、[库存](evidence/20261114-materials-v88/v88-stock-1366.png)、[链路](evidence/20261114-materials-v88/v88-chains-1366.png)、[筛选](evidence/20261114-materials-v88/v88-category-filter.png)、[菜单收起](evidence/20261114-materials-v88/v88-menu-hidden.png)、[新建](evidence/20261114-materials-v88/v88-outbound-editor.png)、[详情](evidence/20261114-materials-v88/v88-outbound-detail.png)。


## 交付

`D:/Users/SunYufei/Downloads/物料布局优化_v88_20261114`：独立完整EXE、同签名APK、说明、14张截图、验收记录及SHA256，无ZIP。隔离浏览器及21314实例已关闭。包含v87及此前功能，无需先安装v87。

| 文件 | SHA256 |
| --- | --- |
| Universal-HMI-20261114-Full-v88-Setup.exe | `f08d272c7db8748177707bfa7fa130344a2a45cb11e7a27bdd84edb88e2dd8f9` |
| Universal-HMI-Android-v88.apk | `7c7f0be0f3bedd4e68e2d8f6dec094d85995cfb529a7e7500fa4f814bd5f944a` |

[发布摘要](evidence/20261114-materials-v88/release-result.json)、[APK核对](evidence/20261114-materials-v88/apk-verification.json)、[最终包重启](evidence/20261114-materials-v88/restart-result.json)、[CI快照](evidence/20261114-materials-v88/ci-summary.json)、[最终包实际截图](evidence/20261114-materials-v88/v88-final-bundle-outbound.png)。
