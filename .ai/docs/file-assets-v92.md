# v92 · 业务图片改为文件存储

2026-11-16，用户要求图片不要塞入数据库，并要求使用成熟技术。本轮采用官方Go CDK v0.47.0 `blob/fileblob`；只增加文件引用、完整性校验与业务接入，不自研对象存储服务。最终Windows/Web同源完整安装包已交付。

## 范围与使用

- 入库凭证、清单/实物照片、个人及历史签名：文件保存到工程data目录下的`objects/sha256`，数据库保留ID、名称、类型、归属、文件引用和单据关联。
- 工艺画面图片/图片背景、自定义共享素材：持久化文档仅含文件引用；现有API、画面读取、JSON/Excel导入导出仍返回自包含图片，界面不需要重新选择图片。
- 总统计报表Excel原稿：整个原稿文件独立保存，保留其内部图片、格式、工作表及既有原稿ID，不拆坏Excel内部关系。
- 设备台账照片已经在`equipment/photos`，继续保留；内置静态素材和GIS资源继续随安装包保存。

没有部署OSS、S3、MinIO服务。图片通过既有鉴权接口读取，对象目录不公开挂到Web。相同内容按SHA256复用文件；Go CDK条件写入配合现有`x/sync/singleflight`合并同工程同内容并发上传。参考：[Go CDK fileblob](https://pkg.go.dev/gocloud.dev@v0.47.0/blob/fileblob)。

## 旧数据、失败及备份

服务启动、开放API前逐条迁移：旧图片/原稿写入对象文件，关闭并回读校验大小和SHA256，然后替换数据库旧载荷。没有改变单据ID、签名版本、库存、画面revision或变量绑定。失败保留当前记录原内容；已成功的记录保留引用，修复后同版重启可继续。不在事务失败时删除共享对象，不自动回收孤立文件。

升级前须保存停机整工程备份；现有工程迁移包递归包含数据库、objects及equipment/photos。仅数据库dump不能恢复附件；缺失或损坏对象明确失败。旧程序不能读取新引用格式，回退须恢复升级前完整工程。逻辑清除旧载荷不保证数据库文件立即缩小，本版不自动执行VACUUM FULL，也不删除历史备份。

## 实际验证

- Go完整test/vet通过。最终新增带PNG的Excel原稿专项通过；Flutter analyze无问题、771项通过/2项既有跳过，前端业务代码未改。
- SQLite和真实隔离PostgreSQL：旧图片/原稿迁移、重开、相同字节、稳定ID/revision、失败后保旧数据及重试通过；PostgreSQL测试独立schema用后删除。
- 工艺画面文件模式及数据库文档模式：共享素材/图片迁出、API继续返回原图片、客户端伪造文件引用拒绝、丢失文件读失败及重启拒绝通过。
- Windows相同内容并发上传专项连续30轮通过；校验损坏、文件缺失、路径越界、取消写入拒绝通过。
- 现有加密整工程迁移包导出/恢复，文件引用与对象内容一并往返通过。此项测试使用合成PG目录，不冒称真实PostgreSQL冷备恢复实测。
- 正常TLS/MFA的旧版隔离业务工程：4张历史图片逐张SHA256相同；6张历史出库单签名接口及Excel内嵌图片逐字匹配；617张申请、17张业务单据、21行明细、10行余额未变；新上传只保存小型引用。该工程无Excel原稿/工艺图片，相关路径由上述专项与PG测试覆盖，不把0条数据算作实测通过。

未部署现场、未改18153。本轮不重跑完整安装/卸载矩阵、原生WebView2/DPI/IME和手机真机。Windows/Web完整EXE、来源与校验值见下方。

## 最终交付

源码`ca1fda0cce9879fd573cd1a38b98730e4a5d310d`；Windows/Web源摘要`1f820de57c59956eb32cdeff9ecdd2d82004d7553506f24d90367620cdd3fd02`。最终相关测试包含引用图片展开大小及数量上限，加载前限制内存；服务迁移后正常TLS/MFA接口与历史签名导出再次验证。运行后端及Web关键文件与包内文件哈希相同。

完整EXE：Universal-HMI-20261116-Full-v92-Setup.exe，286,760,935字节；SHA256：`ac67518554dce2fba7395fc69e3d6dbab47299f0a4889a7ca35cf71182b30ab4`。交付到`D:/Users/SunYufei/Downloads/业务图片文件存储_v92_20261116`，含说明和公开验收证据，无ZIP。隔离服务21316已关闭。

远端CI按最终源码另列：Verify Go and Flutter in_progress。PR #67保持草稿，不将本地验收等同跨平台CI或现场部署。

- [go-test.log](evidence/20261116-file-assets-v92/go-test.log)
- [go-vet.log](evidence/20261116-file-assets-v92/go-vet.log)
- [migration-test.log](evidence/20261116-file-assets-v92/migration-test.log)
- [final-targeted.log](evidence/20261116-file-assets-v92/final-targeted.log)
- [concurrency.log](evidence/20261116-file-assets-v92/concurrency.log)
- [restore-test.log](evidence/20261116-file-assets-v92/restore-test.log)
- [postgres-ux.log](evidence/20261116-file-assets-v92/postgres-ux.log)
- [excel-image.log](evidence/20261116-file-assets-v92/excel-image.log)
- [dependencies.log](evidence/20261116-file-assets-v92/dependencies.log)
- [flutter-analyze.log](evidence/20261116-file-assets-v92/flutter-analyze.log)
- [flutter-test.log](evidence/20261116-file-assets-v92/flutter-test.log)
- [build.log](evidence/20261116-file-assets-v92/build.log)
- [fixture-result.json](evidence/20261116-file-assets-v92/fixture-result.json)
- [release-result.json](evidence/20261116-file-assets-v92/release-result.json)
- [installer-manifest.json](evidence/20261116-file-assets-v92/installer-manifest.json)
- [ci-summary.json](evidence/20261116-file-assets-v92/ci-summary.json)
