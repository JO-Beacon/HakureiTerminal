# Privacy

This document describes HakureiTerminal's data handling. An independently operated Runtime or model Provider has its own privacy policy and data retention practices.

## Local Data

HakureiTerminal stores application settings, non-executable client-authored character drafts, user roles, disposable remote display caches, appearance settings, media, external connection definitions, and diagnostic logs on the device. GensokyoAI `2026.8.8.0`, not this local data, is the sole authority for executable characters, sessions, messages, context, memory, scenes, tools, timers, and generation state.

On Windows, the normal data root is `%APPDATA%/HakureiTerminal/`. Development or platform fallback locations may include `.hakurei_terminal/` and `.hakurei_terminal_settings.json` in the current working directory. Media is stored by SHA-256 content hash. The application does not implement a HakureiTerminal-operated analytics or account service.

`settings.json` can contain secrets in plaintext application data:

- Model Provider API keys and Provider base URLs.
- Dedicated TTS Provider API keys, base URLs, model, voice, and playback settings.
- GensokyoAI Runtime URLs and bearer tokens.
- The identity of a model profile delegated to a Runtime connection.

Protect the device account, backups, and filesystem permissions accordingly.

## Network Transmissions

HakureiTerminal has no first-party chat runtime and never calls a text-model Provider for chat generation, embeddings, tools, or context processing. After an explicit user action, it may read a configured Provider's model list or model metadata to populate the settings UI. Model profiles are also retained so the user can explicitly delegate selected settings to a selected GensokyoAI Runtime. A separately configured TTS Provider receives Markdown-derived readable assistant text only when the user clicks a read-aloud action; code blocks are excluded, and returned audio is stored only in the temporary directory for client playback. Runtime and Provider operators control their own processing and retention.

For an explicitly connected external GensokyoAI connection, HakureiTerminal may send:

- The configured Runtime URL and bearer token in the destination and `Authorization` request header.
- Health, capability, character, session, memory, scene, timer, tool, and other public Runtime RPC requests selected by the user.
- Messages submitted to external sessions and identifiers needed to resume those sessions.
- A model and embedding profile, including Provider API keys, only after explicit Provider delegation and only during `agent.init` for the designated connection.
- A character package only after an explicit upload confirmation, to the selected Runtime's documented public package endpoint.
- Read-only World state, roster, public transcript, and archive-list requests when the Runtime declares `world.orchestration`.

GensokyoAI owns and may persist its native characters, sessions, messages, memory, scenes, tools, timers, and operational logs. HakureiTerminal may keep remote IDs and read-only display snapshots, but those are not authoritative copies of external history. Review the external operator's privacy and retention policy before connecting.

Client-authored character drafts are local, non-executable content. Editing, importing, restoring, or opening the application never uploads them. A character package upload is a separate, explicit action and is limited to the selected Runtime's documented public API and confirmed payload scope.

Saving a connection and opening the application do not make a request. Testing, connecting, and using an external session can make network requests only after an explicit user action. Importing a `.jovarchive` does not contact a Runtime or Provider; imported external connections are disconnected and Provider delegation is cleared.

## Archives

A full `.jovarchive` includes `settings/settings.json`. It therefore includes Provider API keys, Runtime bearer tokens, Runtime URLs, disposable remote display caches, non-executable character drafts, user profile information, and referenced media. Treat every full archive as a sensitive credential backup:

- Do not publish it, attach it to a public issue, or send it through an untrusted channel.
- Store and transfer it with access controls appropriate for API keys.
- Import validates the archive locally and does not upload, synchronize, or auto-map its contents to a Runtime.
- Import restores credentials but leaves external connections disconnected and clears Provider delegation until the user explicitly configures them again.

## Logs And Diagnostics

HakureiTerminal automatically writes structured JSON Lines diagnostic logs on the device. Events can include application and feature lifecycle stages, sanitized endpoint scheme/host/port/path, HTTP or RPC status, elapsed time, byte or item counts, boolean configuration state, and truncated SHA-256 references. Resource references are diagnostic correlations and are not authoritative application or Runtime state.

The shared logger removes URL credentials, query strings, fragments, authentication headers, bearer values, API keys, and sensitive-key values. It does not record request or response bodies, prompts, messages, reasoning, tool arguments or results, TTS input text, character draft content, settings payloads, archive contents, or unredacted local filesystem paths. Unknown exception details are omitted; known transport and protocol errors are reduced to safe summaries. Logging failures do not change application behavior.

Logs rotate at 2 MiB per file with at most five files retained. The data management page can refresh statistics, open the desktop log directory, clear HakureiTerminal logs, or export a diagnostics ZIP containing only `.log` files and `manifest.json`. Clearing writes a new audit event, so one newly created log file can remain. Export and deletion affect only HakureiTerminal-managed logs, not logs written by an independently deployed Runtime, reverse proxy, or Provider.

The diagnostics exporter is designed to exclude credentials and content, but sanitized server hostnames, route paths, timing, platform/version data, and operational metadata can still be sensitive. Review every ZIP before sharing it and do not publish private infrastructure details.

## Deletion

Deleting a local draft, display cache, media item, model profile, connection, log, or application data removes only the selected HakureiTerminal-managed copy. It does not delete:

- Data already sent to or retained by a model Provider.
- GensokyoAI-owned sessions, messages, characters, memory, scenes, tools, timers, configuration, or logs.
- Existing `.jovarchive` exports or other filesystem/cloud backups.
Use the external service's documented controls or contact its operator for external deletion. Delete old archives and backups separately.
