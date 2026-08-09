# GensokyoAI 2026.7.14.0 Runtime Smoke Report

> Historical v1 smoke report. It does not validate the current Agent v2-only client.

## Scope

- Runtime package version: `2026.7.14.0`
- Protocol version: `1.1.0`
- Protocol major: `1`
- Endpoint: loopback HTTP/WebSocket deployment
- Client test path: public `/info`, `/health`, `/rpc`, and `/ws` only
- Secrets: no Runtime token or Provider Key was read, printed, or recorded

## Automated Client Gates

- `flutter analyze`: passed
- `flutter test`: passed
- Windows release build: passed
- Android debug APK build: passed
- Source boundary scan: passed
- Windows artifact boundary scan: passed
- Android artifact boundary scan: passed

## Live Runtime Results

The live smoke uses an explicitly created disposable Runtime session. Cleanup deletes
the disposable session and restores the previously active session.

| Scenario | Result | Evidence |
| --- | --- | --- |
| `/info` and `/health` | Passed | Runtime reported package `2026.7.14.0`, protocol `1.1.0`, initialized and started |
| Read current session and current-character list | Passed | Public `session.current` and `session.list` returned the existing active session |
| Create disposable session | Passed | `session.create` returned and activated a new session ID |
| WebSocket stream completion | Passed | `agent.send_message_stream` returned a valid completion with assistant content |
| Stream cancellation | Passed | Immediate `runtime.cancel_stream` produced a cancelled terminal event |
| Cleanup and restore | Passed | Disposable session was deleted and the original session became current again |
| Immediate authoritative history convergence | Not provided by Runtime | Seven `session.messages` reads over about four seconds remained at the pre-send empty snapshot |

## Windows RC Results

- Explicit connection and existing-session activation: passed.
- Normal streaming response and continued sending: passed.
- Runtime timeout displays an actionable error and does not lock the session: passed.
- Cancellation preserves display state and allows the next explicit send: passed.
- First-send scroll position remains at the newest messages: passed.
- User scroll position is not forced back during later updates: passed.
- GensokyoAI settings loads current session state read-only: passed.
- Opening settings did not initialize, switch, or restore a Runtime session: passed.

## Compatibility Decision

A WebSocket completion is generation success, but it is not evidence that
`session.messages` already contains the completed turn. HakureiTerminal therefore:

1. Keeps completed user/assistant content in an explicitly disposable display-only layer.
2. Does not send that layer back as model context.
3. Does not let an empty or stale history snapshot erase completed display content.
4. Allows further sends while displaying a non-blocking synchronization notice.
5. Clears the display-only layer only after authoritative history contains the ordered user/assistant content.

This is a client compatibility behavior for the observed public Runtime contract. It
does not modify GensokyoAI, write local execution context, or claim that unsynchronized
content has been persisted by the Runtime.

## Remaining Platform Checks

- Physical Android device networking and lifecycle
- Linux candidate build and startup
- Initiative timer event UI reconciliation over its natural timer lifecycle
