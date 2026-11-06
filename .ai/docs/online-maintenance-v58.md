# 线上运维与菜单图标 v58

状态：实施中，尚未交付或部署。

用户要求 Windows、远程网页、KP 与手机均可按权限运维；获授权人员管理用户/角色不得超出自身授权，设备台账仅维护已授权范围。具体合同以 [架构](architecture.md#线上运维权限2026-11-06-v58实施中) 为准。

修改模块：backend/internal/authorization、identity、server、equipment、navigation；app/lib/shared/api.dart、features/security*、role_management、device_*、equipment、process/navigation_icons、online_maintenance 及 main。

验证计划：授权成功/拒绝/越权/CSRF/撤销，直接与角色授权持久化、旧配置兼容，菜单图标导入；Go test/vet、Flutter analyze/test、Windows/Web/安卓构建，隔离实际网页宽窄窗及升级/重装/卸载保数据。沿用现有测试与打包流程，未操作现场或18153。

基线：58069403e83365f221816f59dd4c8e46424e1c57；接手时 Verify Go and Flutter 与 Linux lifecycle regression 均 success，不代表本批通过。
