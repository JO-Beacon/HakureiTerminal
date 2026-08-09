# Privacy

This document describes HakureiTerminal's data handling. An independently operated Runtime or model Provider has its own privacy policy and data retention practices.

## Local Data

HakureiTerminal stores application settings, non-executable client-authored character drafts, user roles, disposable remote display caches, legacy inert conversations/runtime records, appearance settings, media, external connection definitions, and diagnostic logs on the device. GensokyoAI `2026.8.8.0`, not this local data, is the sole authority for executable characters, sessions, messages, context, memory, scenes, tools, timers, and generation state.

On Windows, the normal data root is `%APPDATA%/HakureiTerminal/`. Development or platform fallback locations may include `.hakurei_terminal/` and `.hakurei_terminal_settings.json` in the current working directory. Media is stored by SHA-256 content hash. The application does not implement a HakureiTerminal-operated analytics or account service.

`settings.json` can contain secrets in plaintext application data:

- Model Provider API keys and Provider base URLs.
- GensokyoAI Runtime URLs and bearer tokens.
- The identity of a model profile delegated to a Runtime connection.

Protect the device account, backups, and filesystem permissions accordingly.

## Network Transmissions

HakureiTerminal has no first-party chat runtime and never calls a model Provider for generation, embeddings, tools, or context processing. After an explicit user action, it may read a configured Provider's model list or model metadata to populate the settings UI. Model profiles are also retained so the user can explicitly delegate selected settings to a selected GensokyoAI Runtime; the Runtime and Provider operators control their own processing and retention.

For an explicitly connected external GensokyoAI connection, HakureiTerminal may send:

- The configured Runtime URL and bearer token in the destination and `Authorization` request header.
- Health, capability, character, session, memory, scene, timer, tool, and other public Runtime RPC requests selected by the user.
- Messages submitted to external sessions and identifiers needed to resume those sessions.
- A model and embedding profile, including Provider API keys, only after explicit Provider delegation and only during `agent.init` for the designated connection.
- A character package only after an explicit upload confirmation, to the selected Runtime's documented public package endpoint.

GensokyoAI owns and may persist its native characters, sessions, messages, memory, scenes, tools, timers, and operational logs. HakureiTerminal may keep remote IDs and read-only display snapshots, but those are not authoritative copies of external history. Review the external operator's privacy and retention policy before connecting.

Client-authored character drafts are local, non-executable content. Editing, importing, restoring, or opening the application never uploads them. A character package upload is a separate, explicit action and is limited to the selected Runtime's documented public API and confirmed payload scope.

Saving a connection and opening the application do not make a request. Testing, connecting, and using an external session can make network requests only after an explicit user action. Importing a `.jovarchive` does not contact a Runtime or Provider; imported external connections are disconnected and Provider delegation is cleared.

## Archives

A full `.jovarchive` includes `settings/settings.json`. It therefore includes Provider API keys, Runtime bearer tokens, Runtime URLs, inert legacy conversations, non-executable character drafts, user profile information, and referenced media. Treat every full archive as a sensitive credential backup:

- Do not publish it, attach it to a public issue, or send it through an untrusted channel.
- Store and transfer it with access controls appropriate for API keys.
- Import validates the archive locally and does not upload, migrate, synchronize, or auto-map its contents. Legacy local conversations and Runtime records remain inert.
- Import restores credentials but leaves external connections disconnected and clears Provider delegation until the user explicitly configures them again.

## Logs And Diagnostics

HakureiTerminal maps Runtime failures to stable error categories and does not intentionally log bearer tokens, Provider API keys, authentication headers, or complete sensitive Runtime responses. Do not assume every log or screenshot is harmless: conversation text, file paths, server hostnames, identifiers, and user-enabled request-payload diagnostics can still be sensitive. Review and redact diagnostic material before sharing it.

The data management page can inspect and delete `.log` files in HakureiTerminal's log directory. It does not control logs written by an independently deployed Runtime, reverse proxy, or Provider.

## Deletion

Deleting a local draft, cache, legacy conversation, media item, model profile, connection, log, or application data removes only the selected HakureiTerminal-managed copy. It does not delete:

- Data already sent to or retained by a model Provider.
- GensokyoAI-owned sessions, messages, characters, memory, scenes, tools, timers, configuration, or logs.
- Existing `.jovarchive` exports or other filesystem/cloud backups.
- Old local Runtime directories left by an earlier HakureiTerminal version.

Use the external service's documented controls or contact its operator for external deletion. Delete old archives and backups separately. See `docs/external-runtime-migration.md` before removing legacy local Runtime data.
