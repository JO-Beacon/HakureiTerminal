# Engineering Rules

## Root-Cause-First Fixes

- Reproduce the failure and identify the exact failing boundary before changing behavior.
- Base a fix on concrete evidence such as an exception, protocol trace, persisted state, failing test, or minimal reproduction.
- Do not add speculative encoding changes, retries, timeouts, fallbacks, or compatibility paths without evidence that they address the observed root cause.
- Keep diagnostic instrumentation separate from the eventual behavior fix. Remove temporary instrumentation unless it provides ongoing operational value.
- When evidence disproves an earlier hypothesis, state that directly and discard the hypothesis instead of layering more changes on top.
- Add a regression test that fails for the identified root cause and passes with the fix.

## GensokyoAI Frontend Boundary

- HakureiTerminal is a dedicated frontend for an independently deployed GensokyoAI Runtime. GensokyoAI is the sole authority for executable characters, chat sessions, messages, context, memory, scenes, tools, timers, and generation state.
- HakureiTerminal must not provide a built-in chat runtime, call model Providers directly for generation, embeddings, tool execution, or other model execution, reconstruct GensokyoAI context locally, or fall back to local execution when the service is absent, disconnected, or rejects a request.
- Direct model Provider access is permitted only to retrieve model lists and model metadata after an explicit user action, using a user-configured endpoint and credentials. This exception must not be used for generation, embeddings, context reconstruction, capability execution, health-based fallback, or automatic service switching.
- HakureiTerminal may persist application settings, connection credentials, UI preferences, media, remote resource identifiers, explicitly disposable display caches, and client-authored character drafts. Cached remote data must never become execution context or authoritative service state.
- Client-authored character drafts are local, non-executable content. Editing, importing, restoring, or opening a draft must not contact a Runtime or imply that the draft exists on the server.
- Character upload may be implemented only through a documented public GensokyoAI network API. It must require an explicit user action showing the destination connection and payload scope, and it must not rely on server-local paths, private RPC methods, shared filesystems, or copied upstream implementation.
- Do not embed, vendor, copy, fork, install, launch, or redistribute GensokyoAI source code, wheels, characters, scenes, configuration, documentation, brand assets, Python runtimes, or bridge code in the HakureiTerminal source tree, APK, desktop bundle, installer, or default assets.
- HakureiTerminal connects only after an explicit user action. Saving settings, opening the app, editing a draft, visiting an unrelated page, or importing/restoring data is not consent to connect, upload, retry, or switch services.
- Contributions containing changes to GensokyoAI itself belong in its upstream project. This repository may contain only HakureiTerminal-owned frontend interoperability code, minimal public-protocol fixtures, and tests which do not copy the third-party implementation or payloads.
- These rules apply equally to Windows, Linux, macOS, Android, and future platforms.
