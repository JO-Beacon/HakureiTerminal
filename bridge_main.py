#!/usr/bin/env python3
"""JSON Lines RPC entry point for the HakureiTerminal embedded backend.

Protocol:
- stdin: one JSON object per line, e.g. {"id":1,"method":"character.list","params":{}}
- stdout: one JSON object per line, e.g. {"id":1,"ok":true,"result":...}
- stderr: diagnostic logs only; never parsed by clients.

GensokyoAI is treated as an embedded HakureiTerminal backend component. In
release builds, it is copied next to this file under ``GensokyoAI``. During
source development, pass ``--backend-dir`` or set ``HAKUREI_BACKEND_DIR`` if the
backend snapshot lives elsewhere.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import traceback
from pathlib import Path
from typing import Any, Protocol, cast

ROOT_FOR_IMPORT = Path(__file__).resolve().parent
DEFAULT_BACKEND_PARENT = ROOT_FOR_IMPORT


def configure_import_path(backend_dir: Path) -> None:
    backend_dir = backend_dir.resolve()
    package_dir = backend_dir / "GensokyoAI"
    if not package_dir.exists():
        raise FileNotFoundError(
            "Cannot locate embedded GensokyoAI package. "
            f"Expected {package_dir}. Pass --backend-dir or set HAKUREI_BACKEND_DIR."
        )
    backend_parent = str(backend_dir)
    if backend_parent not in sys.path:
        sys.path.insert(0, backend_parent)


def _default_backend_dir() -> Path:
    env_backend_dir = os.environ.get("HAKUREI_BACKEND_DIR")
    if env_backend_dir:
        return Path(env_backend_dir)
    return DEFAULT_BACKEND_PARENT


def _json_default(value: Any) -> str:
    return str(value)


async def _write_response(response: dict[str, Any]) -> None:
    print(json.dumps(response, ensure_ascii=False, default=_json_default), flush=True)


async def run_bridge(root: Path, runtime_service_type: type[Any]) -> int:
    service = runtime_service_type(root_dir=root)
    loop = asyncio.get_running_loop()

    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if line == "":
            await service.shutdown()
            return 0

        line = line.strip()
        if not line:
            continue

        request_id: Any = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            method = request.get("method")
            params = request.get("params") or {}
            if not isinstance(method, str):
                raise ValueError("Request field 'method' must be a string")
            if not isinstance(params, dict):
                raise ValueError("Request field 'params' must be an object")

            result = await service.handle(method, params)
            await _write_response({"id": request_id, "ok": True, "result": result})
            if method in {"shutdown", "runtime.shutdown"}:
                return 0
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            await _write_response(
                {
                    "id": request_id,
                    "ok": False,
                    "error": _error_payload(exc),
                }
            )


def _error_payload(exc: Exception) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "type": type(exc).__name__,
        "message": str(exc),
        "code": "internal_error",
        "details": {},
        "recoverable": False,
    }

    exc_code = getattr(exc, "code", None)
    exc_details = getattr(exc, "details", None)
    exc_recoverable = getattr(exc, "recoverable", None)
    if isinstance(exc_code, str):
        payload.update(
            {
                "code": exc_code,
                "details": exc_details if isinstance(exc_details, dict) else {},
                "recoverable": bool(exc_recoverable),
            }
        )
    elif isinstance(exc, ValueError):
        payload.update({"code": "bad_request", "recoverable": True})
    elif isinstance(exc, (FileNotFoundError, ImportError, ModuleNotFoundError)):
        payload.update({"code": "missing_resource", "recoverable": True})
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="HakureiTerminal JSON Lines runtime")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Root directory containing characters, config and runtime assets.",
    )
    parser.add_argument(
        "--backend-dir",
        type=Path,
        default=_default_backend_dir(),
        help="Directory containing the embedded GensokyoAI package directory.",
    )
    return parser.parse_args()


class _ReconfigurableTextIO(Protocol):
    def reconfigure(self, **kwargs: Any) -> None: ...


def _reconfigure_text_stream(stream: Any) -> None:
    if hasattr(stream, "reconfigure"):
        cast(_ReconfigurableTextIO, stream).reconfigure(encoding="utf-8")


def main() -> None:
    _reconfigure_text_stream(sys.stdin)
    _reconfigure_text_stream(sys.stdout)
    _reconfigure_text_stream(sys.stderr)

    args = parse_args()
    configure_import_path(args.backend_dir)

    from GensokyoAI.runtime.service import RuntimeService

    raise SystemExit(asyncio.run(run_bridge(args.root.resolve(), RuntimeService)))


if __name__ == "__main__":
    main()
