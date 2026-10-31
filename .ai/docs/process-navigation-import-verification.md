# 工艺包父子菜单与原图升级核验

2026-10-30 实现范围为 backend/internal/transfer、navigation 公开校验及 server 装配。真实站点仍是平铺物理键，父子关系只存在客户端菜单；不改变量归属、MQTT配置、实际历史或运行激活。本轮未操作现场及18153。

## API与JSON

版本1普通JSON bundle增加可选 navigation：`{enabled:true,nodes:[{id:"group",label:"父站",children:[{id:"leaf",label:"一区",screen_key:"包内画面key"}]}]}`。每个叶子引用本次包内画面key，后端解析成实际screen_id；最多4层256项，沿用navigation模块校验。JSON往返保持菜单，XLSX/CSV带导航时明确拒绝，避免静默丢树。

GET process-transfer/catalog增加navigation当前Config（revision/enabled/nodes）。请求navigation_target为 `{mode:"skip"|"create"|"replace",revision:当前revision}`。UI默认skip；缺失或空模式为unresolved，不能提交。create要求现有树为空且未启用；replace必须用户明确选择并提供精确版本，现有自定义菜单不会被默认覆盖。预览navigation条目提供Before旧Config/After解析目标树，旧树进入preview_token。非法树、缺目标、版本冲突和未选择在任何提交写入前闭锁。

画面逐项保存后再通过navigation.Save发布菜单。画面写入失败不发布缺失目标树；菜单存储失败返回failed，已有成功画面保持真实结果并可重试。画面与菜单没有跨模块事务，不能把部分成功报告成全成功。重复同一树返回unchanged，不重复增加修订。

原28图更新使用用户显式批量选择的screen_targets[key] mode=update_imported。后端按非空import_identity、key和映射站点派生原稳定ID，要求目标存在且Station/Kind一致；缺失不新建、不按同名匹配、不接受覆盖到其他ID。预览返回实际ID和当前revision，令牌绑定完整旧文档；预览后并发编辑必须重预览。首次导入仍选create。保留旧import_identity才能精确定位已有图。

## 已通过

固定工具链go1.24.7 windows/amd64，GOTOOLCHAIN=local。

- [全Go test](evidence/20261030-process-navigation/go-test.log)：go test -mod=readonly ./...，退出0。
- [全Go vet](evidence/20261030-process-navigation/go-vet.log)：go vet -mod=readonly ./...，退出0。
- [专项](evidence/20261030-process-navigation/targeted-tests.log)：明确创建/替换/跳过、旧菜单不覆盖、版本冲突、缺screen_key、重复菜单ID、非法叶子/组、导航存储失败重试、真实文件画面保存失败不发布菜单、重复导入、reader拒绝、JSON往返、XLSX拒绝静默丢树；update_imported精确定位、Station/Kind/任意ID拒绝、并发编辑不覆盖。
- 新交付JSON生产Decode→Preview→Commit隔离测试：使用扫描器独立数值FLOAT预期构造5019个现有点，先导旧385需求包的28图，再以相同import_identity和update_imported导新313需求包；5019定义JSON逐字相等，28旧画面ID全部复用，14父菜单/28叶目标全部存在。此为隔离文件工程，未连接MQTT。

## 待发行验收

Flutter UI、Windows/Web构建由UI代理核验；PostgreSQL真实HTTP和安装保留升级、浏览器父子菜单及去右栏视觉由发行代理和root继续。上述Go测试不冒称现场已导入或真实物理分站正确。完整现场变量仍保留稳定ID；用户需确认真实source映射及预览后再提交。
