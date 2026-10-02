# MCP 业务覆盖与客户端合同

本页是传输合同及覆盖清单。代码：`backend/internal/server/mcp*.go`；业务权威仍是既有 points/runtime/storage/analysis 服务。架构母本见 [architecture.md](architecture.md)，认证配置见 [intranet-auth.md](intranet-auth.md)。本轮新增源码和隔离测试，不代表已部署内网、接入真实设备或完成第三方客户端认证兼容验收。

## 协议与连接

`/mcp` 提供无状态 Streamable HTTP，固定支持 MCP `2025-11-25`、`2025-06-18`、`2025-03-26`。初始化请求的版本受支持则原样协商，否则返回 `2025-11-25` 让客户端决定是否继续。没有 `MCP-Protocol-Version` 头时按旧版兼容请求处理；提供不支持的版本头返回 HTTP 400。不是对未来/latest 草案的兼容承诺。

- POST 请求为单个 UTF-8 JSON-RPC 2.0 对象，Content-Type 为 `application/json`，Accept 包含 `application/json, text/event-stream`
- 支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`；声明 tools 能力，固定有界列表不分页、不发送 listChanged
- 客户端先 initialize，再发 initialized 通知，后续携带协商版本头；服务不分配 MCP 会话 ID，不要求服务器保存握手状态
- 有效通知返回 HTTP 202 且无正文；缺少 ID 的 tools/call 不会执行任何业务动作
- 请求返回 JSON；GET /mcp 和 DELETE /mcp 返回 405，不提供独立 SSE 通道、旧 SSE 端点、MCP 会话删除、资源订阅、prompts、采样或任意代码执行能力
- 协议方法未知为 -32601；未知工具或请求信封错误为 -32602；权限拒绝为 -32003；已知工具参数校验及业务操作错误保留内容并返回 `isError:true`
- 每个工具结果同时给出文本 JSON 和 `structuredContent`。业务数据、导入文本和工具描述都不能充当授权或下一步操作指令

依据：官方 [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[工具](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。协议版本被固定，避免把变化中的最新草案当作实现证据。

## 登录、权限与安全

`/mcp` 挂在 HTTP 相同的 Auth.Handler 内。每次启动均为 `read_only`。开放 MCP 修改工具需服务启动显式 `--mcp-write`、当前进程模式 `write`、当前账号 `allow_write:true` 三者交集。可在界面显式切换 `off` / `read_only` / `write`；模式不持久化，写权限不足不能切换，也不能通过请求体提升权限。只读列表隐藏修改工具；知道工具名也不能绕过执行检查。规则预览和导入预览是只读操作，即使底层 HTTP 使用 POST。

认证模式的非浏览器客户端须支持自定义 HTTP 头：通过同一 HTTPS `/api/v1/auth/login` 显式请求 `issue_token:true`，得到当前会话的短期 bearer，并在每次请求设置 `Authorization: Bearer <session token>`。不要将凭据或 bearer 放在 URL、仓库、公开截图或日志中。该会话受相同期限/退出撤销约束；不是静态 API key，不实现 OAuth 授权服务器、自动发现或自动注册，因此不承诺仅支持 OAuth 的 MCP 客户端直接接入。浏览器 cookie 客户端的 POST /mcp（包括只读工具）须提供会话 `X-CSRF-Token`。

认证模式强制实际 TLS、精确公共 Host 和 Origin；不信任客户端转发头。本机无认证模式仅接受 localhost/字面量回环 Host，不能仅凭攻击者自己匹配的 Origin/Host 对放行。每个 MCP HTTP 方法都检查 Origin；内部固定 API 调用保留已验证的 TLS、身份上下文和必要认证头。

没有任意 HTTP URL/方法/路径工具，没有 shell、脚本进程、SQL、调用者文件路径或凭据配置工具。来源连接和声明式控制仍可能接触已配置设备，需在客户端显示风险并由用户确认具体现场动作。工具注解是提示，不能替代上述服务端权限。

## 全部业务操作清单

共 32 个工具，对应 32 个唯一业务 REST method/path。身份校验/登录/退出、静态 Web 文件是安全及展示层，不作为业务工具暴露。只读状态为 R；需要双重修改授权为 W。

| MCP 工具 | 权限 | 既有 HTTP 操作 | 关键语义 |
| --- | --- | --- | --- |
| health_get | R | GET /health | 服务能力 |
| points_list | R | GET /api/v1/points | 保存定义/缩放/偏移 |
| points_create | W | POST /api/v1/points | 保存单点，不自动应用 |
| points_update | W | PUT /api/v1/points/{id} | `id` + `point` 完整定义 |
| points_delete | W | DELETE /api/v1/points/{id} | 删除保存定义 |
| points_create_batch | W | POST /api/v1/points/batch | 原子批量保存 |
| configuration_apply | W | POST /api/v1/apply | 校验并激活配置版 |
| runtime_get | R | GET /api/v1/runtime | 活动版、值、来源、规则、策略、队列 |
| point_sample | W | POST /api/v1/points/{id}/sample | `id` + `sample.value` 原值 |
| point_write_capability | R | GET /api/v1/points/{id}/write-capability | 写类型/工程范围/编码/原因 |
| point_write | W | POST /api/v1/write | command_id、point_id、value、version |
| command_get | R | GET /api/v1/commands/{id} | 发布/ACK/读回对账，不重发 |
| sources_save | W | PUT /api/v1/sources | 保存 sources；不自动连接 |
| source_connect | W | POST /api/v1/sources/{id}/connect | 显式连接既有来源 |
| source_disconnect | W | POST /api/v1/sources/{id}/disconnect | 断开来源 |
| storage_get | R | GET /api/v1/storage | 可选 station；省略为全局 |
| storage_save | W | PUT /api/v1/storage | `station` + `policy` |
| storage_snapshot | W | POST /api/v1/snapshot | 站点/全局持久快照 |
| history_query | R | GET /api/v1/history | 筛选、分页、统计和冻结边界 |
| history_series | R | GET /api/v1/history/series | 1–6 点全区间有界曲线、实际样本/断点、单位/版本统计；max_points 20–600、冻结 before 边界 |
| history_catalog | R | GET /api/v1/history/catalog | 导入/历史身份目录 |
| rules_save | W | PUT /api/v1/rules | 保存含 enabled 的声明式规则 |
| rule_preview | R | POST /api/v1/rules/preview | 同一校验，无保存/执行 |
| executions_list | R | GET /api/v1/executions | 每步结果、部分失败 |
| demo_set | W | POST /api/v1/demo | 显式启停 30 站模拟 |
| import_upload | W | POST /api/v1/import/upload | 文件名 + base64 内容暂存 |
| import_preview | R | POST /api/v1/import/preview | 工作表/列映射校验 |
| import_commit | W | POST /api/v1/import/commit | 幂等提交冻结历史 |
| export_create | W | POST /api/v1/export | 冻结筛选的异步任务 |
| jobs_list | R | GET /api/v1/jobs | 排队/运行/完成/失败/取消 |
| job_cancel | W | POST /api/v1/jobs/{id}/cancel | 取消任务 |
| job_delete | W | DELETE /api/v1/jobs/{id} | 删除任务及其生成文件 |
| export_download | R | GET /api/v1/jobs/{id}/file | 有界 base64 分块下载 |

站点、来源、规则、策略运行概览通过 runtime_get 提供；不虚构当前 REST 没有的发现或独立多工程切换功能。定义 DTO 的完整可选字段（包含 scale_factor、offset、写目标和虚拟表达式）均出现在 tools/list 的 inputSchema。嵌套对象拒绝未知字段；规则动作只允许 write/snapshot/storage_start/storage_stop，write 必须显式数值，条件阈值不能缺失/null。

## 规模与文件边界

- MCP 请求体最多 16 MiB，JSON 最深 32 层，拒绝重复键/无效 UTF-8；同时处理最多 4 个请求，忙时 HTTP 429/Retry-After
- 内部 API 响应最多 32 MiB；超限明确报错，不截断成成功。修改可能已经完成，客户端应查询对账，不能自动重放
- 点位最多 20000；历史单页 1–5000；目录 1–20000；来源 32；规则 200，每条 32 条件/16 动作；来源、点位、规则业务校验仍由既有服务执行
- 文件上传 `filename` 必须是简单 `.csv` / `.xlsx` 文件名。`data_base64` 为标准、无换行、严格填充的 base64；解码后最多 8,384,512 字节，保留 4096 字节给既有 8 MiB multipart 限制
- 既有文件服务继续限制解压体积 32 MiB、16 工作表/100 列/50000 行；不执行宏；8 个导入会话/30 分钟到期
- `import_upload` 返回 session_id 和表预览；`import_preview`/`import_commit` 使用相同 Mapping 字段，time_column/value_column 从零开始。暂存、预览和提交不同
- `export_create` 使用 history_query 同样筛选字段并冻结 before 边界；最多 8 排队任务、64 个任务、50000 行/30 秒，用 jobs_list 观察终态
- `export_download` 仅接收 job id、offset（默认 0）、max_bytes（默认/上限 1048576）。内部固定 Range 请求读取生成文件，返回 filename、mime_type、data_base64、offset、next_offset、total_bytes、eof；逐块拼接到 eof。不会读取调用者路径或把整个大文件加载到 MCP 响应

## 示例请求

以下为请求正文；HTTP 头、认证和用户批准须按前述合同提供，不含实际凭据。

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"hmi-client","version":"1.0"}}}
```

```json
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"history_query","arguments":{"station":"Station 01","limit":500,"offset":0}}}
```

保存缩放需用 points_create / points_update 的 scale_factor、offset；调用 configuration_apply 后才在新运行版生效。写工程值使用 point_write 并提供当前 version 与稳定 command_id。复查 command_get 的独立 publish_state/ack_state/readback_state，不把排队/发布当作设备已执行。

## 回归证据入口

`mcp_test.go` 使用 Go AST 枚举 server.go/platform.go 业务注册，确保每个 method/path 恰好对应一个命名工具；新增 REST 功能没有同步 MCP 覆盖时测试失败。还覆盖握手/通知、版本/媒体类型、恶意参数、默认只读/权限交集、身份转义、HTTPS Origin 传播、请求/响应/并发限制、真实服务换算与历史冻结、预览无副作用、四步声明式动作、幂等 CSV 导入、异步导出和大文件分块。

最终通过/失败记录由本轮验收文档与 CI 补充；不可只因本页存在而宣称认证/协议全量合规或生产部署完成。


## 可见模式与连接测试（2026-10-02）

设置路径 `GET/PUT /api/v1/mcp/settings` 是同一认证边界内的管理界面，不是 MCP 工具，关闭模式下也能恢复。模式写入携带当前 revision；工具清单/调用权限由同一模式和身份判定。第三方客户端应在模式变更后重新读取 tools/list，不能依赖旧清单取得权限。无独立 SSE 推送/工具变更通知。

设置界面显示当前模式、同服务端点、工具数量、启动权限上限与只读账户限制。只有显式“应用模式”才更改；“测试连接”通过真实 JSON-RPC initialize → initialized → tools/list → health_get 检验，沿用既有 CSRF/bearer 与过期清理，拒绝错误信封/工具失败，重复点击不会并发提交。它不创建凭据、不自动从关闭模式恢复、不执行写工具，也不是外部客户端兼容认证。

新增 `point_ids` 逗号分隔筛选覆盖 history_query、history_series 和 export_create（最多6个稳定点ID，不能与 point_id 同时指定）。新业务路由对应第33个命名工具；设置管理路由不进入业务工具清单。模式关闭/只读不撤销此前已受理的设备命令，不能充当急停。
