# Engineering Rules

## Root-Cause-First Fixes

- Reproduce the failure and identify the exact failing boundary before changing behavior.
- Base a fix on concrete evidence such as an exception, protocol trace, persisted state, failing test, or minimal reproduction.
- Do not add speculative encoding changes, retries, timeouts, fallbacks, or compatibility paths without evidence that they address the observed root cause.
- Keep diagnostic instrumentation separate from the eventual behavior fix. Remove temporary instrumentation unless it provides ongoing operational value.
- When evidence disproves an earlier hypothesis, state that directly and discard the hypothesis instead of layering more changes on top.
- Add a regression test that fails for the identified root cause and passes with the fix.

## Mandatory Structured Logging

- Every new feature and every material change to an existing feature must integrate with HakureiTerminal's structured application logger before the work is considered complete.
- Log the feature's user-triggered lifecycle, external-service and persistence boundaries, meaningful state transitions, successful outcomes, rejected operations, and failures with stable event names and actionable metadata such as duration, status code, byte/count totals, capability names, and hashed resource references.
- Logging must be diagnostic without becoming a second source of product state. Log files are disposable diagnostics and must never be read as execution context, used to reconstruct Runtime state, or used as a fallback when GensokyoAI is unavailable.
- Never log Runtime tokens, Provider API keys, Authorization or Cookie headers, URL credentials or queries, request/response bodies, prompts, message or reasoning content, tool arguments/results, TTS input text, character draft content, settings payloads, archive contents, or unredacted local paths.
- Use the shared `AppLogger` redaction, URI sanitization, reference hashing, rotation, clearing, flushing, and export mechanisms. Do not add ad hoc `print`, `debugPrint`, private log files, or feature-specific logging formats.
- Logging must not change feature behavior or turn a successful operation into a failure. Logger I/O failures remain isolated from application behavior.
- Add or update tests which prove that the feature emits the required success/failure events and that representative secrets and content cannot appear in logs or exported diagnostics.

## GensokyoAI Frontend Boundary

- HakureiTerminal is a dedicated frontend for an independently deployed GensokyoAI Runtime. GensokyoAI is the sole authority for executable characters, chat sessions, messages, context, memory, scenes, tools, timers, and generation state.
- HakureiTerminal must not provide a built-in chat runtime, call text-model Providers directly for chat generation, embeddings, tool execution, context processing, or other text-model execution, reconstruct GensokyoAI context locally, or fall back to local text-model execution when the service is absent, disconnected, or rejects a request.
- Direct model Provider access is permitted only to retrieve model lists and model metadata after an explicit user action, using a user-configured endpoint and credentials. This exception must not be used for generation, embeddings, context reconstruction, capability execution, health-based fallback, or automatic service switching.
- This text-model boundary does not prohibit client-owned media features such as text-to-speech. A dedicated TTS Provider may be used only after an explicit user action and with separately scoped credentials; TTS requests and playback must remain client-owned, must not modify Runtime-authoritative messages, context, memory, or generation state, and must not provide a text-generation fallback.
- HakureiTerminal may persist application settings, connection credentials, UI preferences, media, remote resource identifiers, explicitly disposable display caches, and client-authored character drafts. Cached remote data must never become execution context or authoritative service state.
- Client-authored character drafts are local, non-executable content. Editing, importing, restoring, or opening a draft must not contact a Runtime or imply that the draft exists on the server.
- Character upload may be implemented only through a documented public GensokyoAI network API. It must require an explicit user action showing the destination connection and payload scope, and it must not rely on server-local paths, private RPC methods, shared filesystems, or copied upstream implementation.
- Do not embed, vendor, copy, fork, install, launch, or redistribute GensokyoAI source code, wheels, characters, scenes, configuration, documentation, brand assets, Python runtimes, or bridge code in the HakureiTerminal source tree, APK, desktop bundle, installer, or default assets.
- HakureiTerminal connects only after an explicit user action. Saving settings, opening the app, editing a draft, visiting an unrelated page, or importing/restoring data is not consent to connect, upload, retry, or switch services.
- Contributions containing changes to GensokyoAI itself belong in its upstream project. This repository may contain only HakureiTerminal-owned frontend interoperability code, minimal public-protocol fixtures, and tests which do not copy the third-party implementation or payloads.
- These rules apply equally to Windows, Linux, macOS, Android, and future platforms.
