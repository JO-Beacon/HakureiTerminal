# GensokyoAI 专用前端产品迁移计划

> 历史 v1 计划，已被 `docs/gensokyoai-agent-v2-client-contract.md` 取代。当前客户端只支持 Agent v2，且不接入 `world.*`；不得依据下文的 v1 假设继续实施。

## 状态与范围

- 状态：专用前端边界、单一会话控制器、传输状态机、权威会话映射、消息对账、设置/归档旁路清理、公开协议 fixture 和本地构建门禁已完成重构；尚需真实服务的完整冒烟测试和多平台发布环境 operational validation。完成自动化实现不等于已证明真实 Provider、网络、签名或候选产物可运行。
- 目标：HakureiTerminal 不再下载、安装、解包、启动或打包 GensokyoAI，也不提供第一方/内置聊天运行时或直接 Provider 调用。GensokyoAI 由用户或其运维环境独立部署和运行，HakureiTerminal 仅作为 HTTP/WebSocket 专用前端接入。
- 目标服务版本：`GensokyoAI 2026.7.14.0`，其 Runtime 协议为 `1.1.0`、主版本为 `1`。目标部署由指定源码构建，以下协议结论以该版本实现为准。
- 权威边界：GensokyoAI 是可执行角色、聊天会话、消息、上下文、记忆、场景、工具、定时器和生成状态的唯一权威。断线时客户端只能作为配置、非可执行草稿、媒体和一次性展示缓存 UI，不能聊天或本地降级执行。
- 非目标：不修改、复制、vendor 或发布 GensokyoAI 源码；不为其实现私有 API；不把服务端角色文件、会话、消息、上下文、记忆或私有配置同步为 HakureiTerminal 权威数据。

协议基线来自对 GensokyoAI `2026.7.14.0` 公开发布资料、Runtime 实现和上游测试的历史本地研究。研究快照不属于 HakureiTerminal，不进入 Git、发布资产或默认资源；本计划不记录机器专属绝对路径。

## 1. 当前边界与问题

迁移前客户端走本地宿主路径：

```text
HakureiTerminal
  -> BackendManager 下载并解压 GensokyoAI release
  -> PythonBridge 启动本地 Python 子进程
  -> bridge_main.py JSON Lines RPC
  -> GensokyoAI Runtime
```

已移除的主要耦合点如下：

- `lib/services/backend_manifest.dart` 固定 GensokyoAI release URL、版本、许可证和摘要。
- `lib/services/backend_manager.dart` 下载、校验、解压运行时与角色资源，并维护本地安装清单。
- `lib/services/python_bridge.dart` 定位 Python、启动 `bridge_main.py`、维护 JSON Lines 请求和本地子进程生命周期。
- `bridge_main.py` 将 HakureiTerminal 私有 RPC 映射为 GensokyoAI Runtime RPC。
- `lib/services/runtime/*`、`lib/repositories/archive_repositories.dart` 和 `lib/main.dart` 直接依赖 `PythonBridge`。
- Windows release 脚本和 Flutter assets 为 bridge 与嵌入式 Python 准备发布内容。

该模式曾使客户端承担第三方运行时安装、进程管理与本地数据目录职责。当前拓扑为：

```text
HakureiTerminal client
  -> HTTPS / HTTP RPC, WebSocket
  -> independently deployed GensokyoAI Runtime
  -> service-owned GensokyoAI configuration, characters, sessions, memory, tools
```

HakureiTerminal 没有内置聊天能力。连接不到外部服务时，设置、非可执行角色草稿、媒体、惰性遗留数据和展示缓存仍可查看或管理，但不能创建可执行角色、发送聊天消息或直接调用 Provider。

## 2. 已确认的服务端公开契约

### 2.1 服务启动与端点

GensokyoAI `2026.7.14.0` 已提供 HTTP/WebSocket Runtime。其入口默认绑定 `127.0.0.1:8765`，但外部部署可由服务端自行指定 host、port、反向代理和 TLS。

| 用途 | 方法与路径 | 使用方式 |
| --- | --- | --- |
| 存活检查 | `GET /health` | 服务可达性和基本健康状态 |
| 服务发现 | `GET /info` | 等价于 `runtime.info`，用于版本与能力协商 |
| 普通 RPC | `POST /rpc` | JSON RPC 请求和单响应 |
| 流式 RPC | `GET /ws` | WebSocket，承载普通 RPC、流式消息、订阅和取消 |
| Runtime 事件 | `GET /events` | Server-Sent Events，承载主动消息、定时器等异步事件 |

`POST /rpc` 请求和响应结构：

```json
{
  "id": "client-generated-request-id",
  "method": "runtime.health",
  "params": {}
}
```

```json
{
  "id": "client-generated-request-id",
  "ok": true,
  "result": {}
}
```

错误仍通过协议响应表达，客户端必须以 `error.code` 或 `error.error_code` 分支，不能依赖自然语言错误文案。

### 2.2 鉴权与跨域

服务端可通过环境变量 `GENSOKYOAI_RUNTIME_TOKEN` 启用令牌校验。令牌至少 16 个字符，客户端可使用下列任一请求头：

```text
Authorization: Bearer <token>
X-Runtime-Token: <token>
```

浏览器 Origin 请求默认会被拒绝，除非服务端配置允许的 Origin。Flutter 原生客户端不应伪造 `Origin`；服务端、反向代理和部署方负责允许的来源、TLS、网络隔离与防火墙策略。

客户端不应：

- 将令牌写入日志、诊断、异常文本或截图数据。
- 在请求 URL、WebSocket query、角色元数据或聊天消息中携带令牌。
- 自动扫描局域网、尝试默认地址，或自动连接历史服务器。
- 修改服务端 CORS、认证、模型 Key、资源控制或文件系统配置。

### 2.3 协议协商

连接配置保存后和每次显式“测试连接”时，客户端调用 `GET /info` 或 `runtime.info`，至少验证：

- `name` 为预期 Runtime 名称。
- `protocol_major_version == 1`。
- `package_version`、`protocol_version`、`capabilities`、`methods`、`method_specs` 可读。
- 关键方法存在：`runtime.health`、`agent.init`、`agent.send_message`、`session.*`、`character.*`。

同一协议主版本允许新增字段和方法。客户端必须忽略未知字段，并以 `methods` / `method_specs` 判断某一功能是否可用；缺失能力显示为该服务不可用的功能，不得伪造本地替代结果。

`runtime.info.methods` 只列出 `RuntimeService` RPC 方法。`runtime.cancel_stream`、`runtime.subscribe` 和 `runtime.unsubscribe` 是 `2026.7.14.0` HTTP/WebSocket adapter 在 `/ws` 拦截的传输控制方法，不在该 methods 列表中。首版将这些方法作为该固定版本的 adapter 契约实现；未来版本不能仅因 RPC 主版本相同而假定它们存在。

## 3. 目标产品模型

### 3.1 服务连接配置

用新的 `ExternalRuntimeConnectionSettings` 替换现有以安装目录为中心的 `BackendSettings` 外部字段。建议持久化字段：

| 字段 | 用途 | 是否写入导出存档 |
| --- | --- | --- |
| `id` | 本地连接配置 ID | 是，不含秘密 |
| `display_name` | 用户自定义显示名称 | 是 |
| `runtime_kind` | 初期固定 `gensokyoai` | 是 |
| `base_url` | 用户明确输入的服务根 URL | 是 |
| `transport_preference` | 固定 `http_rpc + websocket_streams` 的协议实现 | 是 |
| `auth_token` | Runtime 访问令牌 | 是，敏感数据 |
| `expected_protocol_major` | 初期为 `1` | 是 |
| `last_verified_at` | 最近成功握手时间 | 是 |
| `last_runtime_info` | 经过脱敏的能力摘要 | 是 |
| `enabled` | 是否允许会话选择该连接 | 是 |

HakureiTerminal 的 `settings.json` 是 Provider Key、Runtime 访问令牌和连接配置的权威存储；`.jovarchive` 是可携带的完整用户存档，默认包含这些凭据，以便在另一设备恢复相同的模型与外部服务连接。此为产品决策，不使用 OS 凭据存储替代或拆分保存。

因此，设置文件和 `.jovarchive` 都是敏感文件，必须按秘密数据处理：

- 不得写入日志、诊断、异常文本、截图数据、Flutter build 常量或 Git。
- 导出前 UI 必须明确提示该归档包含 Provider Key 和服务令牌，不能公开分享。
- 导入前 UI 必须明确提示归档包含凭据，并列出将恢复的连接与 Provider 配置；用户确认前不得写入本地设置或连接服务。
- 存档预览、完整性校验、媒体扫描和错误报告必须省略或脱敏凭据字段。
- 删除连接或 Provider profile 时，必须同时删除 `settings.json` 与后续导出中对应的凭据；已生成的旧 `.jovarchive` 只能由用户自行删除或重新导出。

本次迁移不保留 `backend_path`、`backend_version`、`backend_source_url`、`backend_sha256`、本地安装清单或自动更新字段的行为。旧设置必须在一次明确的数据迁移中转换为“未配置外部连接”，而不是猜测可用 URL。

### 3.2 数据权威矩阵

“权威”指该数据的最终写入、冲突裁决和删除位置，不等于客户端不能保存脱敏索引或短期展示快照。每个外部资源的本地键必须至少包含 `connection_id + remote_id`，禁止只用服务端 ID 作为全局键。

| 数据类别 | 权威方 | 客户端允许写入 | 客户端允许缓存 / 归档 | 冲突与删除规则 |
| --- | --- | --- | --- | --- |
| HakureiTerminal 设置、UI 偏好 | HakureiTerminal | 本地设置 API | `settings.json`、`.jovarchive` | 导入经确认后原子替换或合并；从不反向写入服务端 |
| 外部连接定义与 Runtime token | HakureiTerminal | 新增、编辑、启用、禁用、删除连接 | `settings.json`、`.jovarchive`，均按敏感数据处理 | 删除连接默认只删除本地定义和映射，不删除服务端数据 |
| Provider profile、模型参数与 Key | HakureiTerminal | 本地 profile CRUD；仅经确认委托给一个指定 Runtime 实例 | `settings.json`、`.jovarchive`；普通缓存只能保存无秘密摘要 | 绝不由客户端直接调用 Provider；本地值不因服务端返回值自动改写；`2026.7.14.0` 没有服务端持久副本 |
| 客户端创作角色草稿 | HakureiTerminal | 仅作为非可执行草稿 CRUD | 完整本地草稿和 `.jovarchive` | 编辑、导入、恢复和启动均不上传；当前没有上传功能，未来须有文档化公开网络 API 及目标连接/payload 范围确认 |
| GensokyoAI 原生角色 | 指定 GensokyoAI 服务 | 仅调用能力清单明确支持的公开角色操作 | `connection_id`、外部角色 ID、名称、版本 / 更新时间和脱敏展示摘要 | 刷新以服务端为准；丢弃服务返回的 `path` 字段；本地删除仅移除映射；不复制角色 YAML 或私有路径 |
| 遗留本地会话、消息、上下文和 Runtime 数据 | 无执行权威；惰性历史数据 | 不进入聊天执行路径 | 可离线保留或归档 | 不自动映射、上传、恢复为服务端状态或作为生成上下文；附件/媒体可独立保留 |
| GensokyoAI 会话元数据 | 指定 GensokyoAI 服务 | 通过公开 `session.*` 创建、恢复、切换或删除 | 外部 ID、最后观察时间、服务端版本标识（如有）和展示快照 | 刷新以服务端为准；服务端删除后本地标为不可用，不重建同 ID 会话 |
| GensokyoAI 消息与生成状态 | 指定 GensokyoAI 服务 | 通过 `agent.*` 发送、取消；不直接编辑服务端消息存储 | 可保存只读展示快照、流 request / stream ID 和同步游标 | 完成 / 失败以服务端终帧或查询结果为准；客户端草稿不算服务端消息 |
| GensokyoAI 记忆、场景、工具与主动定时器 | 指定 GensokyoAI 服务 | 仅通过 `runtime.info` 宣告的公开方法操作 | 外部 ID、能力状态、最后观察值和同步时间 | 重连后刷新；本地快照不得回放为写操作，不导入到另一连接 |
| 外部运行状态、资源限制和能力 | 指定 GensokyoAI 服务 | 无；客户端只发探测与业务请求 | 脱敏 `last_runtime_info` 和最近健康结果 | 每次显式重连重新协商；缓存只供离线展示，不能启用已消失的能力 |
| 外部事件去重状态 | HakureiTerminal（派生状态） | 按连接和订阅更新 | 仅保存当前连接生命周期的最小事件 ID，不包含消息正文或秘密 | 只能防止当前连接内的 UI 重复消费；`2026.7.14.0` 不提供事件回放或恢复游标，断线后必须刷新服务端状态 |

`.jovarchive` 只携带 HakureiTerminal 设置、非可执行草稿、惰性遗留记录以及外部资源的映射 / 展示快照，不携带服务端权威的完整角色、会话、消息、上下文、记忆、场景、工具或定时器数据。导入不会联网、上传或自动映射任何遗留数据；外部连接保持禁用，只有用户确认对应 URL、token 和 Provider 委托范围后才能重新连接。

### 3.3 外部状态冲突与生命周期规则

1. 外部会话被选中时，聊天 UI 使用服务端 `session.*` 和 `agent.*` 结果作为运行状态来源。客户端快照只用于列表、排序和断线展示，必须标注最近同步时间。
2. 发送前生成客户端请求 ID；只有服务端接受响应或流开始帧到达后，消息才进入“已提交”状态。断线、超时或未知结果不得合成成功消息，重试前须先按公开 API 查询或由用户明确确认。
3. 若服务端提供 revision、更新时间或事件 ID，客户端保存并用于去重 / 条件写入；若未提供，则不实现离线编辑、自动合并或无提示重放。
4. 重连顺序固定为：重新鉴权、重新读取 `runtime.info`、重新建立单一事件通道、刷新当前会话与必要状态，最后才允许继续发送。缓存能力不能跨重连直接沿用。
5. 服务端资源在客户端缓存期间被修改时，下一次成功刷新直接采用服务端值；本地只读展示快照被覆盖，不产生双向合并。
6. 服务端资源不存在时，本地映射进入“远端已删除 / 不可访问”状态。用户可删除本地映射，但客户端不得用缓存内容自动重建远端资源。
7. 删除外部会话或角色必须显示目标连接和远端资源，并单独确认。删除本地连接、删除本地映射和调用服务端删除是三个独立操作，不做级联猜测。`2026.7.14.0` 不存在客户端可撤销的 Provider 持久副本。
8. `.jovarchive` 导入不向任何外部服务发请求。导入完成后，连接保持禁用，直到用户查看目标 URL 与凭据范围并显式启用或测试。
9. 多设备同时使用同一服务时，HakureiTerminal 不声明分布式锁所有权。公开 API 没有并发控制字段的资源不得提供可能覆盖服务端状态的离线编辑。
10. `2026.7.14.0` 的 `session.messages` 读取完整历史、没有分页或 revision；`session.replace_messages` 以全量列表替换服务端历史。首版外部会话只读；在没有服务端 revision / 条件写入 API 前，不暴露历史编辑、替换、回滚或再生操作，避免覆盖另一客户端刚写入的内容。
11. `session.export` 会返回服务端 `root_dir`、配置路径和角色路径等部署信息。HakureiTerminal 不调用它来构建 `.jovarchive`，也不存储、展示或上传其中的 Runtime 路径字段。
12. 客户端角色草稿的编辑、导入、恢复和应用启动完全离线。`2026.7.14.0` 当前没有可用的文档化角色上传网络 API，因此产品不提供上传；未来上传必须独立确认目标连接和 payload 范围。

### 3.4 用户流程

1. 用户在“服务连接”中新建 GensokyoAI 连接，手动输入 URL、显示名称和令牌。
2. 用户显式点击测试连接。
3. 客户端向 `/info` 和 `/health` 发起请求，显示服务版本、协议版本、能力和认证结果。
4. 验证通过后，用户显式启用连接，并可把它选为新会话的外部运行服务。
5. 用户选择要为该连接委托的 Provider profile。确认页显示目标服务、Provider、模型、包含的 Key 字段，以及“当前 Runtime 实例，直到服务重启或再次初始化”的授权范围。
6. 客户端仅在用户确认后将该 profile 作为 `agent.init` override 委托给选定服务；未获得确认不得发送 Provider Key。
7. 客户端通过 `character.list`、`session.list` 读取服务端资源；用户选择角色和会话后，客户端保存外部 ID 映射。
8. 消息默认经 WebSocket `agent.send_message_stream` 流式发送；其帧结构和取消语义按本版本公开 adapter 契约实现，不自动降级为 HTTP 聚合请求。
9. 主动消息、定时器和状态变化首版经单一 WebSocket `runtime.subscribe` 同步到 UI；不同时建立 SSE `/events` 订阅。
10. 断线后 UI 显示连接已断开，不自动创建服务、启动进程、重试风暴或切换到其他服务；用户可明确点击重连。

## 4. 客户端技术设计

### 4.1 新传输层

新增 HakureiTerminal 自有的服务端协议客户端，例如：

```text
lib/services/runtime/http_runtime_client.dart
lib/services/runtime/runtime_connection.dart
lib/services/runtime/runtime_protocol.dart
```

职责：

- URL 规范化与 HTTPS / HTTP 安全校验。
- 为 HTTP 和 WebSocket 请求附加令牌请求头，并仅在用户确认后将 Provider profile 映射为 `agent.init` 的公开 override 字段委托给选定 Runtime 实例；在日志和错误中脱敏。
- 生成请求 ID，关联并发 RPC 响应，解析标准 `ok/result/error` 信封。
- 执行 `/info`、`/health` 探测与协议主版本校验。
- 管理一个连接配置对应的 WebSocket 会话、流式消息、`runtime.subscribe` / `runtime.unsubscribe` 和 `runtime.cancel_stream` 请求。
- 将服务端事件转换为现有 `ExternalRuntimeEvent` 或新的中立事件模型。
- 明确区分连接、认证、协议、RPC、流和服务端资源限制错误。

不得把 GensokyoAI 的 Python 实现、HTTP adapter 代码、默认配置或角色数据复制到这些文件。实现只能依据稳定公开 JSON 契约。

### 4.2 接口去耦

`ExternalAgentRuntime` 目前由 `GensokyoAiRuntimeClient(PythonBridge)` 实现。迁移时将它改为依赖一个小型中立协议接口，例如 `RuntimeRpcTransport`：

```dart
abstract interface class RuntimeRpcTransport {
  Stream<ExternalRuntimeEvent> get events;
  Future<dynamic> call(String method, Map<String, dynamic> params);
  Future<void> connect();
  Future<void> disconnect();
}
```

然后由 `GensokyoAiHttpRuntimeClient` 实现该接口或直接实现 `ExternalAgentRuntime`。目标是 UI、管理页、角色源和聊天运行层不再导入 `python_bridge.dart`。

需要替换的直接依赖包括：

- `GensokyoAiRuntimeClient`。
- `GensokyoAiBackend` 与 `GensokyoAiAgentThinkingEngineAdapter`。
- `GensokyoAiAssistantProviderAdapter`。
- `AssistantArchiveRepository` 中的角色部署、角色包处理和 `externalBridge` 字段。
- `lib/main.dart` 的 bridge 生命周期、stderr 订阅、运行时事件订阅和可用性判断。

### 4.3 方法映射

优先采用 Runtime 公开的命名空间方法，禁止新增 `hakurei_terminal.*` 服务端私有桥接方法。

| 当前客户端用途 | 外部 Runtime 方法 | 备注 |
| --- | --- | --- |
| 探测 | `runtime.info`、`runtime.health` | 也可调用 `/info`、`/health` |
| 初始化角色 / Agent | `agent.init` | 仅传公开 API 需要的参数 |
| 普通发送 | `agent.send_message` | HTTP RPC 可用 |
| 流式发送 | `agent.send_message_stream` | WebSocket 逐帧消费 |
| 取消流 | `runtime.cancel_stream` | 仅 WebSocket |
| 事件订阅 | `runtime.subscribe` / `runtime.unsubscribe` | `2026.7.14.0` 首版仅 WebSocket |
| 外部角色列举 | `character.list` | 不使用本地 `assistant.list` 桥接语义 |
| 外部会话 | `session.create/list/current/resume/messages/delete` | 服务端状态为权威；首版历史只读 |
| 记忆 / 场景 / 定时器 | 现有 `memory.*`、`scene.*`、`initiative_timer.*` | 先由 capability gate 控制 |
| 角色包 | 当前不调用 | 不传服务端路径；未来仅可使用文档化公开网络上传 API，并要求目标连接和 payload 范围确认 |

`RuntimeRequest` 不能再直接整体传给旧 `agent.run` 桥接接口。实施时根据 `2026.7.14.0` 的 `agent.init`、`agent.send_message` 和 adapter 契约，单独定义并测试 HakureiTerminal 到公开 Runtime 参数的映射。

### 4.4 流与事件策略

`2026.7.14.0` 首版使用 WebSocket 作为外部会话和事件的唯一传输：

- 发送 `agent.send_message_stream` 后，逐帧接收 `{id, ok, stream_id, event}`；成功结束时接收 `{id, ok: true, stream_id, done: true, result}`。
- 对每个流保存服务端 `stream_id`，用户取消时发送 `runtime.cancel_stream`。
- 通过 `runtime.subscribe` 订阅与当前连接相关的 Runtime 事件。
- WebSocket 关闭后使所有未完成流进入明确失败或取消状态；不合成成功消息。
- 忽略心跳帧 `{ok: true, type: "heartbeat", ts}`，但把持续缺失心跳与 socket 关闭作为连接状态信号。
- 事件帧包含 Runtime 事件 ID、类型、来源、时间和服务端已脱敏的数据；事件队列溢出会以 `runtime.backpressure.dropped` 事件表示，客户端收到后必须刷新相关服务端状态。
- `2026.7.14.0` 的稳定事件契约不声明 `message.sent`；客户端以 `initiative_timer.triggered` 请求会话历史协调。该事件 payload 不含 session ID，因此只能协调当前选中且已激活的会话，不能据此更新后台会话。

SSE `/events` 不进入首版。它没有事件 ID 续传或服务端回放契约，且与 WebSocket 订阅并用会重复消费主动事件和定时器事件。

### 4.5 Provider 配置与 Key 同步

Provider Key 可在用户确认后委托给 GensokyoAI Runtime 实例，但其权威来源仍是 HakureiTerminal 的 `settings.json` 和 `.jovarchive`。委托行为必须绑定到特定 `connection_id`，不能自动应用到其他服务连接。

该版本只支持一种模式：`session` 委托。`2026.7.14.0` 的公开 `agent.init` 参数包含 `model_overrides` 和 `embedding_overrides`；两者分别允许 `provider`、`name`、`base_url` 和 `api_key`。聊天模型的 `model_overrides` 还允许 `api_path`、`extra_headers`、流式和生成参数。未知 override 字段会被忽略，客户端必须只发送该版本已确认的字段。

调用 `agent.init` 时，Runtime 从其自身配置文件载入配置，再把 override 应用于当前内存中的 Agent；公开 RPC 方法表没有 Provider 配置的持久化写入、读取或删除 API。因此该行为不是可管理的服务端 profile，也不应描述为“当前会话独占”：同一 Runtime 服务实例随后重新 `agent.init` 会替换其当前 Agent。HakureiTerminal 必须把授权范围显示为“当前外部 Runtime 实例，直到该服务重启或再次初始化”，并禁止对同一连接的并发 Agent 初始化。

`persistent` Provider 同步在 `2026.7.14.0` 明确不支持，不显示设置入口、不创建远端副本、也不提供虚假的撤销操作。未来版本只有在公开契约声明持久化写入、脱敏读取和删除方法时，才能单独设计该模式；不得通过 SSH、文件共享、服务端路径、私有 RPC 或未文档化接口绕过。

会话委托的参数映射、错误脱敏和连接隔离由 HakureiTerminal 客户端测试覆盖：只向选定 `connection_id` 的 `agent.init` 发送 Key，传输日志与错误模型不保存 Key，且并发连接的请求状态完全隔离。真实模型 Provider 成功或失败属于用户配置和第三方 Provider 的运行结果，不改变此 Runtime 契约。

### 4.6 安全与网络限制

实现前先定义并测试 `RuntimeEndpointPolicy`：

- 默认只允许 `https`。
- `http://127.0.0.1`、`http://localhost` 可作为用户显式录入的本地开发服务例外。
- 是否允许其他私网 HTTP 地址必须由明确需求和测试决定，不能默认开放。
- 拒绝带用户名密码的 URL、文件 URL、非 HTTP(S) scheme、含令牌 query 的 URL 和解析后不安全的重定向。
- 禁止自动发现、广播、端口扫描和 URL 重定向跨主机后继续携带 Authorization。
- 所有诊断只保存 URL 的脱敏形式和 HTTP 状态，不保存 Authorization、`X-Runtime-Token`、RPC 请求内容或模型 Key。

服务端 token 是用户秘密。该版本 `/rpc` 在请求 ID 尚未解析前发生的认证失败会返回 HTTP `400` 和 `ok: false` 的结构化错误信封，而 `/health` / `/info` 直接返回 HTTP `401`。客户端必须同时检查 HTTP 状态和 RPC error code / envelope，不能把所有 `400` 一概归类为输入无效。UI 只展示稳定错误类别，例如“无法连接”“认证失败”“协议不兼容”“服务端拒绝请求”，不回显 token 或完整敏感响应。

## 5. 分阶段实施计划

### 阶段 0：契约基线与测试夹具（已完成）

交付：冻结一份 HakureiTerminal 自有的 `2026.7.14.0` API 适配矩阵和协议测试夹具，不复制第三方文档全文。

1. 将已确认端点和方法编码为客户端 fixture：`/health`、`/info`、`POST /rpc`、`/ws`，以及 `runtime.info`、`agent.init`、`agent.send_message`、`session.list`、`session.messages`、`character.list`。
2. 将 `agent.init` 映射固定为最小初始化字段与 `model_overrides` / `embedding_overrides` 的已确认字段。客户端只发送其拥有的配置字段，绝不整体透传旧 `RuntimeRequest` 或 Python 数据类。
3. 将 `persistent` Provider 同步固定为 `unsupported`：该发行版没有公开 Provider 配置写入、读取或删除 RPC。测试仅覆盖实例级 `session` 委托及两个 `connection_id` 的隔离。
4. 为 WebSocket fixture 固定流事件帧、结束帧、错误帧、取消确认、订阅事件、心跳和 `runtime.backpressure.dropped`；首版不实现 SSE 事件接收或自动 transport fallback。
5. 为正确、错误、缺失 Runtime token，协议主版本不匹配、未知方法、未知字段、资源限制和 `ok: false` 建立最小测试夹具；`/rpc` 的 HTTP `400` 结构化认证错误必须与 JSON 输入错误区分。
6. 固定外部会话能力边界：使用 `session.create/list/current/resume/delete/messages`，不实现 `session.replace_messages`、`session.regenerate_from`、`session.rollback` 或 `session.export` 的客户端路径。
7. 固定外部角色和角色包边界：使用只读 `character.list`；不使用依赖服务端文件路径的 `character_package.*` 操作，也不部署本地角色。

阶段 0 的夹具只保留公开 JSON 契约的最小脱敏样例，不复制第三方源码、文档全文、角色、配置或运行时文件。每项能力标记为 `supported`、`unsupported` 或 `out_of_scope`，不以未执行的网络 trace 阻塞实现。

验收：所有客户端路径都能追溯到该版本公开 adapter / Runtime 方法；没有根据私有函数建立客户端依赖。

### 阶段 1：连接配置与安全存储（已完成）

交付：用户可以新增、测试、启用、禁用和删除外部服务连接，但尚不改变聊天主路径。

1. 引入连接配置模型、Provider profile 与 Key 的 settings/archive 序列化、脱敏状态模型。
2. 在设置页替换“下载 / 安装运行服务”卡片为“服务连接”。
3. 增加 URL、显示名称、令牌输入、测试连接、能力摘要和删除连接操作。
4. 仅在用户点击测试连接、显式委托 Provider profile 或选择使用外部会话后请求服务；应用启动不自动连接，也不自动选择或降级传输通道。
5. 将旧的本地安装设置迁移为“未配置外部连接”并显示一次迁移说明；不创建连接占位，不推断 URL，不启动旧 bridge。

验收：Provider Key 和令牌仅持久化于 `settings.json` 与用户明确导出的 `.jovarchive`；只有用户确认实例级委托后才可短暂进入发往指定连接的请求内存，不出现在日志、调试页或错误信息；导入导出均有敏感数据确认；未配置或未连接服务时配置、草稿和缓存 UI 可用，但聊天不可用。

### 阶段 2：HTTP RPC 客户端与管理 API（已完成）

交付：设置页可通过公开 HTTP RPC 管理外部服务的健康、会话、记忆、场景、定时器与工具状态。

1. 实现 RPC 信封、错误映射、请求 ID 和 `/info` 协商。
2. 用 HTTP Runtime transport 替代 `ExternalAgentRuntime` 对 `PythonBridge` 的依赖。
3. 迁移现有管理页调用到 `runtime.*`、只读 `session.*`、`memory.*`、`scene.*`、`initiative_timer.*`、`external_tool.status`；外部会话历史编辑能力保持禁用。
4. 所有页面根据 `runtime.info.methods` 和 capabilities 启用或禁用操作。
5. 对 HTTP 401、403、429、断网、无效 JSON、RPC `ok: false`、协议主版本不匹配、Key 脱敏和未确认同步增加回归测试。

验收：关闭或删除 `PythonBridge` 后，外部运行服务管理功能仍可通过 `2026.7.14.0` 契约测试夹具工作。

### 阶段 3：会话与角色读取（已完成）

交付：客户端可以选择外部服务连接、读取外部角色、浏览和恢复外部会话。

1. 以 `character.list` 取代 `assistant.list`，为服务端角色定义只读映射模型。
2. 以 `session.list/current/resume/create/messages` 取代本地 bridge 会话管理；外部消息历史只读，不调用 `session.replace_messages`、`session.regenerate_from` 或 `session.rollback`。
3. 为本地 `ChatSession` 增加 `external_connection_id`、`external_session_id`、`external_character_id` 等明确映射字段；避免把服务端私有路径写入本地档案。
4. 将本地会话列表中的外部会话标记为“服务端状态”，断线时显示最后已知摘要而不是允许编辑为本地权威副本。
5. 移除“把 HakureiTerminal 角色部署到 GensokyoAI”的流程。草稿编辑、导入、恢复和启动不得上传；当前无上传功能，未来仅可依据文档化公开网络 API，并通过独立确认显示目标连接和 payload 范围；不得通过服务端文件路径或私有端点绕过。

验收：服务端角色和会话不需要存在于客户端本地路径；多个连接的 ID 不会冲突；删除本地映射不会删除服务端会话，除非用户在 UI 中明确调用服务端删除操作。

### 阶段 4：聊天流、主动事件与断线处理（已完成）

交付：外部 GensokyoAI 会话以 WebSocket 流式收发消息，并正确反映服务端主动事件。

1. 实现 `agent.init`、`agent.send_message_stream`、完成帧、错误帧和 `runtime.cancel_stream` 映射。
2. 将流式内容转为现有 `RuntimeStreamEvent`，保证取消、失败和完成状态互斥。
3. 实现单一 Runtime 事件通道，映射 model、tool、后台任务、错误和主动定时器事件到 UI；不假设存在未在该版本事件枚举中声明的 `message.sent` 事件。
4. 断线时取消未完成 UI 状态、关闭订阅、清理请求映射；不自动启动服务或无限重连。
5. 重新连接后重新协商能力，并从服务端刷新当前会话、消息与定时器状态。

验收：发送、取消、服务端错误、主动消息、连接中断和重新连接均有 `2026.7.14.0` 契约集成测试；消息不会重复保存或在断线后被误标记为成功。

### 阶段 5：移除本地集成与发布资产（已完成）

交付：HakureiTerminal 的源码树、构建和发布包不再包含 GensokyoAI 本地运行、安装或 Python bridge 逻辑。

1. 删除 `BackendManager` 的下载、摘要校验、解包、角色资源下载和本地安装状态代码。
2. 删除 `backend_manifest.dart` 中 GensokyoAI release、摘要、角色资产和本地 adapter 定义。
3. 删除 `PythonBridge`、根目录 `bridge_main.py`、Python 资产准备脚本、嵌入式 Python runtime 准备和 release 拷贝逻辑。
4. 删除不再需要的 Python requirements、Android Chaquopy host 与相关 Android Python 测试，除非产品另有独立的一方 Python 需求并另行规划。
5. 更新 Windows、Linux、Android 构建文件、README、第三方说明、设置页、开发脚本和测试，确保不再宣称或尝试安装 GensokyoAI。
6. 检查 release tree、APK、桌面 bundle、installer 与默认 assets，确认不含 `GensokyoAI` 包、第三方角色、场景、配置、bridge、Python runtime 或其依赖。

验收：在无 Python、无 GensokyoAI 目录的干净机器上，HakureiTerminal 可构建、启动并使用配置、草稿、缓存、媒体和归档 UI，但不能聊天；服务仅在用户明确操作选定 URL 后以网络 API 使用。

### 阶段 6：迁移、文档与发布验证（本地工作已完成）

交付：现有用户不会被静默连接到旧运行时，且能理解外部服务迁移方式。

1. 明确旧本地安装目录、运行时数据和角色部署记录的弃用策略：默认不删除、不上传、不自动迁移；在数据管理页提供说明与用户明确删除操作。
2. 更新用户文档：如何单独启动 GensokyoAI、如何设置 HTTPS/令牌、如何配置 HakureiTerminal 连接、服务端与客户端数据所有权。
3. 更新隐私和安全说明：客户端传输哪些数据到外部服务，服务端保存哪些数据，令牌的存储与导出规则。
4. 在 CI 中增加源码和发布产物扫描，阻止 GensokyoAI 源码、wheel、角色、场景、配置、文档、Python runtime 和 bridge 重新进入 HakureiTerminal 发行物。

验收：迁移文档覆盖从全新安装到最小连接；更新安装不会下载、启动或自动连接任一第三方服务，归档导入不联网且恢复连接默认禁用。

## 6. 测试策略

### 单元测试

- URL endpoint policy、URL 规范化、重定向与私网规则。
- Authorization / `X-Runtime-Token` 与 Provider Key 注入、日志脱敏、settings/archive 序列化和导入导出确认。
- RPC 信封序列化、响应 ID 路由、错误对象转换和未知字段容忍。
- `runtime.info` capability gate 与协议主版本校验。
- WebSocket 流状态机：启动、增量、完成、错误、取消、断线。
- `2026.7.14.0` WebSocket 帧：流 `event` / `done`、取消确认、订阅事件、`runtime.backpressure.dropped` 和心跳。
- 外部 ID 到本地 UI 映射；多连接隔离；导出时包含秘密且有明确敏感数据确认。
- 外部快照只读、服务端删除后的映射状态、未知提交结果不自动重试以及重连后能力重新协商。
- `.jovarchive` 导入阶段零网络请求，恢复的外部连接默认禁用，用户确认后才能测试或启用。
- 旧 `BackendSettings` 到新连接配置的迁移，不猜测服务器 URL。

### 集成测试

- 使用测试双桩模拟 `/health`、`/info`、`/rpc`、`/ws` 的标准契约；`/events` 只保留协议兼容测试，不进入首版事件路径。
- 使用 `2026.7.14.0` adapter 契约测试夹具完成协议回归测试，不将服务端源码或运行时放入本仓库。
- 认证失败、错误 token、服务停止、协议不兼容、资源限制 `resource.limit_exceeded`、服务端 `ok: false` 和 WebSocket 断线。
- `agent.send_message_stream` 内容帧、结束帧和取消帧的 UI 与存档行为。
- Runtime 主动事件和定时器事件不会重复写入；队列溢出后刷新服务端状态；不使用 SSE 作为并行事件通道。

### 发布验证

- `flutter analyze`、`flutter test`、Windows/Linux/Android 构建。
- 解包桌面 release 和 APK 后扫描禁止项：`GensokyoAI/`、`bridge_main.py`、`runtime_http.py`、`python/runtime`、第三方角色、场景和默认配置。
- 在不安装 Python 的环境启动桌面应用。
- 在未配置外部连接、无网络和服务端不可达场景下验证聊天明确不可用，同时配置、非可执行草稿、缓存、存档和设置仍可使用且不会联网。

## 7. 固定限制与当前结论

1. `agent.init` 和 `agent.send_message_stream` 按固定公开字段映射，不使用旧 `agent.run` bridge 参数。
2. `2026.7.14.0` 没有公开 Provider 持久化 CRUD；当前只支持经确认的 Runtime 实例级委托。
3. 当前没有角色上传或本地角色部署。客户端角色仅为非可执行草稿；未来上传须有文档化公开网络 API 和明确的目标连接/payload 范围确认。
4. 远程服务的 host、TLS、反向代理、认证、防火墙、日志和备份由部署方负责。
5. Provider Key 与 Runtime token 保存在 `settings.json` 和完整 `.jovarchive`；归档按敏感凭据备份处理。
6. 外部历史只读，Runtime 是外部角色、会话、消息、记忆、场景、工具和定时器的权威方。
7. 首版为固定版本使用单一 WebSocket 流和订阅通道，不启用 SSE fallback。

## 8. 完成定义

实现完成标准及当前结果：

1. HakureiTerminal 不下载、安装、解压、启动、嵌入或发布 GensokyoAI 与其 Python 依赖、角色、场景、配置或文档。
2. 用户通过明确操作配置一个独立 GensokyoAI 服务 URL 和令牌，客户端才会连接。
3. 外部服务客户端仅使用公开 `/health`、`/info`、`/rpc`、`/ws` 契约，不依赖第三方私有源代码、文件路径或桥接 RPC。
4. 外部服务不可用时，HakureiTerminal 仍可管理设置、非可执行草稿、惰性遗留记录、缓存、媒体和存档，但不能聊天、执行角色或直接调用 Provider。
5. Provider Key 和令牌仅持久化于用户本地 `settings.json` 与用户明确导出的 `.jovarchive`；仅在用户确认后发送给指定连接，且不会进入日志、诊断、Git、Flutter build 常量或发布产物。
6. GensokyoAI 对可执行角色、会话、消息、上下文、记忆、场景、工具、定时器、生成状态和服务端配置的唯一权威性在 UI、数据模型和文档中一致；遗留本地会话/runtime 数据保持惰性且不自动映射或上传。
7. 单元、集成和源码边界扫描可在本地执行；干净发布包必须通过 artifact scanner，不含禁止的第三方运行时内容。

以上本地可完成的代码、公开协议 fixture、单一会话状态机、竞态回归测试、迁移、文档和 scanner 项均已实施。该状态只表示自动化与本地构建门禁完成，不表示真实服务已通过 operational validation。剩余工作是针对真实 `GensokyoAI 2026.7.14.0` 部署执行连接、角色/会话激活、历史恢复、创建、流式发送、取消、跨角色切换、主动定时器、断线和显式重连冒烟，并对 Windows/Linux/Android 候选物执行启动、网络、签名和 artifact 验证；这些验证不得通过恢复本地 Runtime、直接 Provider 调用或本地执行 fallback 完成。
