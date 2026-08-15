# Security Policy

## Reporting A Vulnerability

Do not open a public issue containing an exploitable vulnerability, API key, Runtime token, archive, private server URL, personal conversation, log with secrets, or proof-of-concept that puts users at risk.

Use GitHub's private vulnerability reporting for this repository if the repository's Security page offers that feature. If it is not enabled, contact the maintainers through a public project channel only to ask them to establish a private reporting channel; do not include vulnerability details or secrets in that public request.

A useful private report includes the affected version and platform, impact, minimal reproduction, relevant sanitized logs, and whether the issue is known to be actively exploited. HakureiTerminal's “设置 -> 数据管理 -> 日志管理 -> 导出诊断日志” action creates a ZIP intended for diagnosis, but you must still review it for private server addresses and operational metadata before sharing. Remove all credentials and personal data unless a maintainer explicitly arranges a secure need-to-know transfer.

Issues in GensokyoAI itself or in a model Provider should be reported to that upstream project or service. HakureiTerminal maintainers can address the first-party client, archive, transport, and integration boundary but cannot secure an independently operated Runtime or Provider deployment.

HakureiTerminal is only a dedicated frontend. GensokyoAI `2026.8.8.0` (Runtime protocol major `2`) is the sole execution and chat-state authority; disconnected operation cannot chat and must never fall back to local execution or direct text-model Provider execution. Direct text-model Provider access is limited to user-triggered model list and model metadata reads. A separately configured TTS Provider may receive readable assistant text only after a user clicks the read-aloud action and must not alter Runtime state or provide text generation.

## Deployment Guidance

- Use HTTPS/WSS for every non-loopback Runtime. Plain HTTP is intended only for explicitly configured `localhost`, `127.0.0.1`, or `::1` development endpoints.
- Enable a strong Runtime token, restrict network access, and configure TLS, reverse proxy, firewall, updates, logs, and backups on the independently deployed service.
- Never place a token in a URL, query string, screenshot, issue, shell history, or source file.
- Treat `%APPDATA%/HakureiTerminal/settings.json` and every full `.jovarchive` as credentials because they can contain text-model and TTS Provider API keys and Runtime tokens.
- Delegate a Provider profile only to a Runtime instance and operator you trust. Revoking delegation prevents future initialization from sending the profile but cannot erase secrets already received by that process.
- Treat character drafts and remote display caches as local-only, non-authoritative content. Editing, importing, restoring, or starting the app must not upload them. Character package upload, when used, requires an explicit destination, file, and option confirmation and uses only the documented public Runtime endpoint.
- Run the repository and release boundary scanners documented in `README.md` before release.

## Supported Versions

Security fixes are expected to target the current HakureiTerminal development line. External Runtime interoperability currently targets GensokyoAI `2026.8.8.0` protocol major version `2`; this statement is a compatibility target, not a promise to distribute or maintain that third-party software.
