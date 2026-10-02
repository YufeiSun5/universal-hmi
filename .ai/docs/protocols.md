# 第一版接入合同

唯一架构母本：[architecture.md](architecture.md)。以下是本仓库的实际 adapter、运行服务和自动测试合同，不是任意厂商版本或真实现场的兼容保证。

## 来源、站点与稳定身份

来源定义包含 `id`、`name`、`broker`、`topic`、`protocol`，其中 `protocol` 为 `generic` / `kep` / `kingio`。KingIO 来源另有 `client_id`、`writer`、`ack_timeout_ms`。`client_id` 是 KIO 网关协议身份，用于拼接主题；不是本程序的 MQTT 会话 ID。示例仅用于本机测试：

~~~json
{"id":"local-kio","name":"Local KIO fixture","broker":"tcp://127.0.0.1:1883","topic":"datachange_fixture","protocol":"kingio","client_id":"fixture","writer":"hmi","ack_timeout_ms":5000}
~~~

broker 使用 `tcp://` 或 `ssl://`，不允许 URI 用户名密码。Source、来源持久配置和运行状态中没有认证字段。MQTT broker 用户名密码、自定义证书及 KIO 写认证均不通过当前 HTTP/UI 来源配置提供。adapter 的 `ConnectWithOptions` 可通过 `ConnectionOptions.KIOAuth` 注入仅本次连接使用的认证，供受控测试/装配使用；这些字段禁止 JSON 序列化，不写入来源和状态，也不把认证或原始 broker 错误带入结果。公开参考中的认证示例不得复制为默认值。

来源最多 32 个，连接必须显式启动；断开后手工重连，重启不自动连接。保存来源不是建立连接，保存点位不是运行激活。点位保存后通过 `POST /api/v1/apply` 激活，返回运行配置版本。

点位通过 `source_id + topic + source_path` 索引到源事实，然后以 `station` 组织。空点位 topic 表示匹配该来源下同一路径的实际消息主题。即使多个 broker 使用相同主题和路径，来源 ID 仍隔离点位身份；不按 MQTT 数组下标匹配。名称、稳定点位 ID、来源、读取路径、写入来源和写入路径分别保存。

当前是一个本地工程下的逻辑站点，独立多工程/账号权限隔离尚未实现。点位配置上限为 20000，支持 `POST /api/v1/points/batch` 的整批校验、一次保存；30 站 × 500 点是当前验证目标，不能将配置上限当作已完成容量验收。

## MQTT 读取与 KIO 默认属性

generic：

~~~json
{"points":[{"path":"IO-01.temperature","value":21,"quality":"good","timestamp":"2026-10-01T00:00:00Z"},{"path":"IO-02.temperature","value":22,"quality":"good","timestamp":"2026-10-01T00:00:00Z"}]}
~~~

kep（Kepware values 格式，`t` 为 Unix 毫秒）：

~~~json
{"values":[{"id":"Channel.IO01.temperature","v":21,"q":true,"t":1790812800000},{"id":"Channel.IO02.temperature","v":22,"q":false,"t":1790812800000}]}
~~~

kingio 的真实格式以 `Objs` 描述本次有更新的对象，`PVs` 提供默认属性：

~~~json
{"Objs":[{"N":"IO01.temperature","1":21,"2":150},{"N":"IO02.temperature","2":0},{"N":"IO03.running","1":false,"2":-100,"3":0},{"N":"IO04.unavailable","1":null}],"PVs":{"1":22,"2":"2026-06-08 10:30:00.000 +0800","3":192}}
~~~

- `N` 是读取源路径，`1` 是值，`2` 是时间，`3` 是质量码
- 默认 `1` 和 `3` 只补充本次 `Objs` 中已经存在、且省略了对应字段的对象；缺失/空 `Objs` 不产生更新，不更新其他已配置点
- 明确的 `1:null` 跳过该对象，不继承默认值；数值 0 和布尔 false 是有效的显式值
- 只有明确的质量码 192 才是 good，允许数字或数字字符串；缺失、null 或其他质量码为 bad
- 当 `PVs.2` 字段存在时，数字型 `Objs[].2` 是相对该基准的毫秒偏移，可为零或负数。上例第一个样本的源时间是 `2026-06-08T02:30:00.150Z`
- 基准时间支持带偏移的 KIO 文本格式和 RFC3339Nano；也支持参考实现中的本地时区文本格式及正的 Unix 秒/毫秒数。无时区文本按后端本地时区解释，建议固定使用带偏移格式
- 无基准字段时，对象时间可以是上述绝对时间；省略对象时间时使用基准，再回退到根 `WriteTime`
- 基准存在但损坏时，数字对象时间绝不能重新解释成 Unix 时间；仅在另有合法 `WriteTime` 时回退，否则拒绝该消息

generic 仅 `quality=good` 判为有效；kep 仅明确 `q=true` 判为有效。需要更新的对象缺失/非法时间时拒绝消息。运行时继续检查数据类型、乱序、源时间和陈旧状态；坏质量、缺失、陈旧及公式失败不触发条件事件。

公开参考只读审阅范围：[KIO 协议交接说明](https://github.com/YufeiSun5/edge-terminal-SPT/blob/main/backend/docs/KIO-MQTT%E5%8D%8F%E8%AE%AE%E4%BA%A4%E4%BA%92%E4%BA%A4%E6%8E%A5%E6%96%87%E6%A1%A3.md)（blob `8238b13822aff990bd80ec5366cb734984a1902c`）及 [kio.go](https://github.com/YufeiSun5/edge-terminal-SPT/blob/main/backend/internal/protocol/kio/kio.go)（blob `6585639e1c81437ee337016ece88ffcf58155661`）。本实现没有迁入检测业务、客户配置或凭据；质量缺失一律无效，不沿用参考中的宽松质量默认。

## 有界队列与状态计数

MQTT 回调仅检查大小、复制原始字节并尝试入队。每连接由一个 worker 按到达顺序解码，JSON 解码、运行映射和数据库写入均不在网络回调执行。每个样本保留真实 MQTT `Retained` 与回调接收时刻 `ReceivedTime`。

- 每条 MQTT 消息最多 1 MiB、10000 个对象；每连接原始消息队列默认 128 条，内部装配可设置 1–4096
- 满队列丢弃新消息并计数，既不无界扩容，也不以 MQTT QoS 代替应用层接受/持久化
- `source_metrics[source_id]` 的 `received`、`accepted`、`processed`、`dropped`、`queued`、`in_flight`、`decode_errors` 都按消息计数，包含 ACK；`samples` 单独计规范化数据行
- 每连接满足 `received = accepted + dropped`，`accepted = processed + queued + in_flight`；解码失败计入 processed 和 decode_errors，不伪装成有效样本
- 来源计数生命周期为本次连接，重连重置。运行层另有 128 批有界队列，分别公开 accepted/processed/dropped batches 与 samples，以及排队/处理中的批数；adapter 已接受不代表运行层已接受，更不代表历史已经落库

## 写入能力、换算与异步命令

`GET /api/v1/points/{id}/write-capability` 由后端返回当前点位的 `writable`、`data_type`、工程值 `min/max`、运行 `version`、写来源、协议与不可用 `reason`。界面使用这一合同决定写入控件；实际请求仍再次验证能力和版本。

物理 KIO 写入要求点位 `writable=true` 且 `rw_mode` 为 `W` 或 `RW`，写来源已连接且配置了 `client_id` 和 `writer`。写来源优先 `write_source_id`，否则读取来源；写路径优先 `write_path`，否则 `source_path`。generic 还要求点位 `write_topic`。当前物理 Kepware 写和 STRING 写不支持；虚拟点不可写。

工程值 = 原值 × `scale_factor` + `offset`。下设校验工程值范围后做逆换算，FLOAT 要求有限数，INT 要求逆算后的原值是整数；缩放 INT 的工程值可为小数。BOOL 使用恒等换算，HTTP 输入显式数字 0 或 1，KIO 线上也是数字 0/1。

例如 `scale_factor=2`、`offset=10`，原值 21 显示为 52，下设工程值 70 对应原值 30。

~~~json
{"command_id":"unique-command-id","point_id":"stable-point-id","value":70,"version":"current-runtime-version"}
~~~

发送到 `POST /api/v1/write`；物理命令返回 accepted 表示意图已保存、已进入有界工作队列。通过 `GET /api/v1/commands/{id}` 查询后续结果。发布和等待 ACK 在独立 worker 执行，不持有全局运行锁等待网络。

状态分别记录 `publish_state`、`ack_state`、`readback_state`、KIO `qid` 及阶段时间：accepted → sent → acknowledged → readback_confirmed 不是同一种成功。失败为 failed；无法判断设备结果时为 unknown，禁止自动重发。同命令 ID、点位、工程值与版本重复请求返回原结果；同 ID 不同请求拒绝。意图在发布前持久化，重启不恢复物理发布队列。

运行写队列最多 32 个待执行任务、4 个 worker、64 个未结束命令；每个 KIO 连接最多 32 个等待 ACK 的请求。手工/模拟点的本地更新可标 readback_confirmed，但不是物理设备确认。

## generic 与 KIO 线上写合同

generic 发布到点位 `write_topic`：

~~~json
{"command_id":"unique-command-id","path":"IO-01.setpoint","value":30}
~~~

generic 的 QoS 1 PUBACK 只表示 broker 收到，结果最多为 sent，ACK/物理读回标明 unsupported。

KIO 主题按来源 `client_id` 和 `writer` 构造：

| 用途 | 主题 |
| --- | --- |
| 数据订阅的约定名称 | `datachange_{client_id}`；实际使用显式 Source.topic |
| 写请求 | `setdata_{client_id}` |
| 写 ACK 订阅 | `setdata_result_{client_id}_{writer}` |
| 全量查询的协议名称 | `Query_AllKIOTags_{client_id}` |

全量查询主题提供 adapter 名称辅助函数，当前连接流程不会自动发布全量查询。写请求使用 QoS 1、非 retained，payload 示例省略认证：

~~~json
{"Writer":"hmi","WriteTime":"2026-06-08 10:30:00.000 +0800","Qid":123456,"PNs":{"1":"V","2":"T","3":"Q","4":"F","5":"S"},"PVs":{"1":0,"2":"2026-06-08 10:30:00.000 +0800","3":0},"Objs":[{"N":"IO-01.setpoint","1":30}]}
~~~

仅受控装配注入认证时才带 `Username`/`Password`。Qid 由 adapter 生成；在发布前登记等待项，避免 ACK 早于 PUBACK 到达时丢失。ACK 示例：

~~~json
{"Qid":123456,"ProcessStep":100,"Result":"OK","Time":"2026-06-08 10:30:00.500 +0800"}
~~~

只有本请求的 Qid、`ProcessStep=100` 且 `Result` 去首尾空格后大小写不敏感等于 OK 才是 acknowledged。其他完整终态 Result 是失败；其他 Qid、中间步骤、retained ACK、发布前收到或截止后收到的 ACK 都不能确认。缺字段/错误类型不当作成功。PUBACK 与设备 ACK 分开记录。

`ack_timeout_ms=0` 使用 5000 ms，上限 30000 ms，ACK 截止从实际发布启动时刻计算。PUBACK 等待自身最多 3 秒；发布确认或设备 ACK 超时后结果 unknown，不自动重放。成功 ACK 后最多再等 30 秒物理读回；未确认读回时保留 ACK 成功并把 readback 标为 unconfirmed。

物理 readback 必须来自点位配置的读取来源/主题/路径，质量和类型有效、值匹配，且源时间和接收时间均晚于该命令实际发布启动时刻。retained、发布前数据、其他来源/点位、坏质量、过远未来时间和旧配置数据不得确认。读回可早于 ACK 到达，但最终 readback_confirmed 必须同时具备正确 ACK；发布时不直接把实时值改成写目标。

验收使用本机模拟网关和自动测试，具体执行结果以当前提交的验证记录为准；真实 PLC/KingIO 现场的协议版本、权限、时钟与负载仍需专门验收。

## 站点存储、虚拟点与事件

`GET /api/v1/storage?station=...` / `PUT /api/v1/storage?station=...` 读取/保存独立站点策略；策略包括启用、周期、变化存储、保留天数和点位范围。`POST /api/v1/snapshot?station=...` 按该站点及点位范围冻结快照。空 station 仍代表全工程策略/动作；它和站点策略分别保存，不是账户权限边界，同时启用重叠策略时可能重复记录相同采样事实。

规则可带 station；该规则的条件和写目标必须属于所选站点，snapshot、storage_start、storage_stop 也作用于该站点。点位迁站后旧站规则输入变为未知，旧历史保留冻结的站点归属。规则配置会持久化，但重启一律禁用执行；存储策略可恢复，且不依赖界面或检测任务。

虚拟点通过稳定输入 ID 和 `v[0]`、`v[1]` 等索引表达受限算术/比较/条件公式。激活检查依赖环、表达式长度、输入数及节点上限；不开放进程、文件系统或数据库。

事件支持 AND/OR、多条件、持续满足时间、冷却、rising/periodic/recovery，动作调用同一受控写入/快照/存储服务。规则预览不产生副作用，执行保存每步返回状态；物理写动作 accepted 是排队结果，最终设备结果应按命令 ID 查询。跨设备和数据库没有原子事务，未知输入不触发事件。
