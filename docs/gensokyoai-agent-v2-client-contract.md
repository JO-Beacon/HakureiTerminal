# GensokyoAI Runtime 2.2 客户端契约

记录日期：2026-08-08

适配目标（只读核对）：`C:\Users\27548\Desktop\gensokyoai-2026.8.8.0`

- GensokyoAI package：`2026.8.8.0`
- Runtime protocol：`2.2.0`（major `2`）
- 公开契约来源：上游 `docs/runtime_api.md` 及公开 HTTP/WebSocket 入口

本文记录 HakureiTerminal 实际采用的公开客户端边界。GensokyoAI 是可执行角色、Agent、会话、消息、上下文、记忆、场景、工具、定时器和生成状态的唯一权威。

## 连接与健康

- 连接只由明确用户操作触发。保存设置、启动应用、编辑或导入本地草稿均不连接 Runtime。
- 连接验证依次读取 `runtime.info`、`GET /health` 和 `GET /ready`。
- 客户端只接受 `protocol_major_version == 2`，要求 Agent v2 消息、会话、状态查询和 WebSocket start ack 能力；没有 v1 或本地执行 fallback。
- 远程地址要求 HTTPS；仅 loopback 主机允许 HTTP。HTTP 不跟随重定向。
- 非空 token 通过 `Authorization: Bearer ...` 同时用于 HTTP、媒体下载和 WebSocket。

## Agent、会话与消息

- 每个连接持久化客户端生成的 `agent_id`；所有资源请求显式携带 `agent_id`，会话资源显式携带 `session_id`。
- `session.list` 和 `session.messages` 按 `has_more` / `next_cursor` 读取全部页面。游标不前进或返回 `pagination.invalid_cursor` 时停止并要求重新读取。
- 每次写会话携带当前权威 `expected_revision`。
- 每次消息操作生成 UUID `idempotency_key`。同一操作重试必须复用原 key。
- WebSocket 先读取 start ack 的 `stream_id` 和 `generation_id`；取消使用服务端确认的 `stream_id`。
- reasoning、工具事件和正文分离显示，不把 reasoning 或工具载荷拼入回复正文。
- 断线或超时后先读 `message.status`，再读 `session.messages` 对账。`message.operation_outcome_unknown` 时重新读取会话，确认后才能使用新 key 发送。

## Runtime 事件

- `runtime.subscribe` 显式携带 `agent_id` 和 `replay_limit`。
- 客户端读取稳定的 `event_id`、`sequence`、`recorded_at`，并兼容同一 2.2 事件中的 `id`、`timestamp` 展示字段。
- 连接生命周期内保存最后 `sequence`；重连订阅用 `after_sequence` 恢复，避免漏掉断线窗口事件。
- 心跳帧不进入业务事件流。背压丢弃和已声明的主动定时器事件触发权威会话对账。

## 管理能力

- 会话、语义记忆、场景、外部工具和主动定时器均通过公开 RPC 管理。
- Provider 模型列表和模型元数据由用户在设置页明确触发后，使用用户配置的 Base URL 和凭据直接读取；不调用 Runtime `model.list`。结果仅作为可丢弃的 UI 数据，不用于客户端执行模型。
- `memory.add` 支持 `content`、`topic_name`、`importance` 和 `emotional_valence`。
- 主动消息总开关使用 `initiative_timer.update(enabled: bool)`。`initiative_timer.hesitation*` 已退役且设置会被上游忽略，客户端不再调用或展示它。
- Runtime 没有只读主动消息总开关的方法；UI 初始显示未知状态，只有用户明确设置后才显示服务端回显，避免伪造权威状态。
- `authorization.forbidden`、`agent.limit_exceeded`、`pagination.invalid_cursor` 和消息结果未知均提供专门的用户错误语义。

## 媒体与角色包

- 用户在消息编辑器选择图片时只读取本地文件；按下发送后才调用 `POST /media?agent_id=...`。
- multipart 文件字段固定为 `file`。上传成功后消息 content parts 引用 `media_id`，不发送本地路径。
- Runtime 历史中的媒体引用通过带认证头的公开下载 URL 显示；缓存不成为执行上下文。
- 角色管理只上传用户选择的现成 `.gensokyo-character` 包，不把本地草稿隐式转换或上传。
- 上传前确认框显示目标连接、Agent、文件名、大小、locale、overwrite 和 allow_untrusted 范围。确认后才调用 `POST /character-packages`。
- 角色包上传需要 `admin` 角色且 Runtime 启用 remote admin。权限或信任检查失败时不做私有 RPC、共享路径或本地执行 fallback。

## 明确排除

- HakureiTerminal 不调用任何 `world.*`。客户端在发起网络请求前显式拒绝该命名空间。
- 不读取 Runtime 服务端磁盘、不复制上游实现、不安装或启动 GensokyoAI，不直接调用模型 Provider 执行生成、Embedding、工具或上下文处理。直接 Provider 访问仅限用户明确触发的模型列表和模型元数据读取。
- 不把本地角色草稿、显示缓存或旧存档恢复成服务端执行状态。

## 验证边界

仓库测试覆盖公开请求 envelope、分页、revision、幂等、流 ack、状态恢复、事件游标、multipart 上传、结构化图片消息、管理 RPC 和 `world.*` 发网前拒绝。

真实 Runtime 冒烟不由离线测试替代；需要用户提供已启动的 `2026.8.8.0` Runtime 地址、具备相应角色的凭据和可用 Agent 后另行执行。
