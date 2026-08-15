# External Runtime Setup

HakureiTerminal is a dedicated frontend for an independently deployed GensokyoAI Agent v2 service over HTTP/WebSocket. That service is the sole authority for executable characters, sessions, messages, context, memory, scenes, Worlds, tools, timers, and generation state. The client requires Runtime protocol major version `2` and has no v1 fallback. When `world.orchestration` is declared, the client can read public World state, roster, transcript, and archive lists.

Client-authored character drafts are local and non-executable. Editing, importing, restoring, or opening a draft performs no network request. Character package upload requires a documented public GensokyoAI network API and a separate confirmation showing the destination connection and exact payload scope.

## Deploy GensokyoAI Separately

Obtain and deploy a GensokyoAI release that publicly exposes Runtime protocol major version `2`. Follow upstream instructions to install dependencies, select a data directory, configure native characters and Provider access, and start the HTTP Runtime.

HakureiTerminal does not verify, install, update, start, stop, or remove that deployment. The service operator is responsible for its license, artifact integrity, host/port, authentication, TLS certificate, reverse proxy, firewall, CORS policy, Provider configuration, logs, backups, and deletion.

For a service reachable beyond the same machine, expose it only through HTTPS/WSS and appropriate network controls. Plain HTTP is accepted by HakureiTerminal only for explicitly entered loopback hosts: `localhost`, `127.0.0.1`, and `::1`.

## Configure HakureiTerminal

1. Open “设置 -> 服务管理 -> 外部服务连接”.
2. Add a display name, the Runtime base URL, and its token. Enter the root URL, not `/info`, `/rpc`, or `/ws`; do not put credentials or query parameters in the URL.
3. Save the connection. Saving is local and performs no network request.
4. Click “测试连接”. HakureiTerminal calls `runtime.info` through `/rpc`, then `/health`, verifies protocol major version `2`, and checks the required Agent v2 methods and WebSocket stream protocol.
5. Use the explicit connection action for the verified profile. The action negotiates `runtime.info` again and opens `/ws`; subscription occurs only after `agent.init`, using the connection's persisted `agent_id`.
6. Select external characters and sessions exposed by that service. The client reads the authoritative session `revision`; sends carry `expected_revision` and a UUID `idempotency_key`. After a disconnect or timeout it checks `message.status` before reconciling `session.messages` and never falls back to v1 or local execution.

Application startup does not connect a saved Runtime. Use the explicit connection action after each startup. Imported archives always restore connections disconnected and do not initiate networking.

## Provider Delegation

GensokyoAI can use Provider configuration managed entirely on its own server. This is the safest separation when the Runtime operator should not receive credentials from HakureiTerminal.

Alternatively, click the key action for a connection and explicitly confirm delegation of the current HakureiTerminal model profile. On a later `agent.init`, the client sends that profile's model and embedding Provider settings, including API keys, to that one Runtime instance. The Runtime does not receive the profile merely because the connection was saved, tested, or connected.

HakureiTerminal retains text-model profiles for this explicit delegation. It may also read a user-configured text-model Provider's model list or model metadata only after an explicit refresh action; it never uses that Provider for generation or other text-model execution. A separately configured TTS Provider is a client-owned media feature and is requested only after the user clicks a message read-aloud action.

Delegation is instance-level initialization data, not a persistent Provider profile managed by HakureiTerminal on the server. It lasts until service restart, another initialization, or local revocation. Revocation blocks future delegation but cannot remotely erase credentials already received. Do not delegate to a Runtime or operator you do not trust.

## Archives And Authority

Full `.jovarchive` files include local Provider keys and Runtime tokens. Import is an offline operation: it validates and restores HakureiTerminal data without contacting any Runtime or Provider, then disables restored external connections and clears delegation.

The archive can carry local drafts, client settings, media, and external ID/display caches. It does not contain the authoritative GensokyoAI characters, sessions, messages, context, memory, scenes, tools, timers, configuration, or server files. Back up authoritative service data with tools provided by the external Runtime operator.
