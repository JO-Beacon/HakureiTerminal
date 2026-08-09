#!/usr/bin/env python3
"""Enforce HakureiTerminal's owned source and release artifact boundary."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Iterable


GENSOKYOAI_METADATA = re.compile(
    r"^gensokyoai(?:[-_.].*)?\.(?:dist-info|egg-info)$", re.IGNORECASE
)
GENSOKYOAI_WHEEL = re.compile(r"^gensokyoai(?:[-_.].*)?\.whl$", re.IGNORECASE)
PYTHON_DLL = re.compile(r"^(?:python(?:\d+(?:\d+)?)?|python3)\.dll$", re.IGNORECASE)
FORBIDDEN_CLIENT_EXECUTION_SYMBOLS = (
    "BuiltinChatBackend",
    "BuiltinChatThinkingEngineAdapter",
    "BuiltinChatModelValidator",
    "ProviderRegistry",
    "OpenAiProviderAdapter",
    "AnthropicProviderAdapter",
    "ModelProviderResolver",
    "JovBuiltinAssistantProviderAdapter",
)
FORBIDDEN_DIRECT_PROVIDER_ENDPOINTS = (
    "api.openai.com",
    "api.anthropic.com",
)


def _parts(name: str) -> tuple[str, ...]:
    return tuple(part.casefold() for part in name.replace("\\", "/").split("/") if part)


def _has_sequence(parts: tuple[str, ...], sequence: tuple[str, ...]) -> bool:
    width = len(sequence)
    return any(parts[index : index + width] == sequence for index in range(len(parts) - width + 1))


def source_violation(name: str) -> str | None:
    """Return the source-boundary rule violated by a repository-relative path."""
    parts = _parts(name)
    if not parts:
        return None
    if "gensokyoai" in parts:
        return "GensokyoAI package component"
    if GENSOKYOAI_WHEEL.fullmatch(parts[-1]):
        return "GensokyoAI wheel"
    if any(GENSOKYOAI_METADATA.fullmatch(part) for part in parts):
        return "GensokyoAI package metadata"
    if parts[0] == "characters":
        return "legacy root character payload"
    return None


def source_content_violation(name: str, content: str) -> str | None:
    """Reject active client execution code while allowing migration prose/fixtures."""
    parts = _parts(name)
    if not parts or parts[0] != "lib" or not parts[-1].endswith(".dart"):
        return None
    for symbol in FORBIDDEN_CLIENT_EXECUTION_SYMBOLS:
        if symbol in content:
            return f"forbidden local execution symbol {symbol}"
    lowered = content.casefold()
    for endpoint in FORBIDDEN_DIRECT_PROVIDER_ENDPOINTS:
        if endpoint in lowered:
            return f"direct Provider endpoint {endpoint}"
    return None


def artifact_violation(name: str) -> str | None:
    """Return the artifact-boundary rule violated by an artifact-relative path."""
    parts = _parts(name)
    if not parts:
        return None
    if parts[-1] in {"bridge_main.py", "runtime_http.py"}:
        return "application Python bridge"
    in_python_runtime = _has_sequence(parts, ("python", "runtime"))
    in_asset_python = _has_sequence(parts, ("assets", "python"))
    if in_python_runtime or in_asset_python:
        if parts[-1] in {"python", "python.exe"} or PYTHON_DLL.fullmatch(parts[-1]):
            return "bundled Python executable or DLL"
        return "application-owned Python runtime layout"
    if "gensokyoai" in parts:
        return "GensokyoAI package or payload"
    if GENSOKYOAI_WHEEL.fullmatch(parts[-1]):
        return "GensokyoAI wheel"
    if any(GENSOKYOAI_METADATA.fullmatch(part) for part in parts):
        return "GensokyoAI package metadata"
    if parts[0] in {"characters", "scenes"}:
        return f"legacy root {parts[0]} payload"
    if len(parts) >= 2 and parts[0] == "config" and parts[1] == "default.yaml":
        return "legacy root default configuration payload"
    return None


def _git_tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", os.fspath(root), "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return [os.fsdecode(item) for item in result.stdout.split(b"\0") if item]


def scan_source(root: Path, tracked_files: Iterable[str] | None = None) -> list[str]:
    """Scan tracked files which are still present in the working tree."""
    names = _git_tracked_files(root) if tracked_files is None else tracked_files
    violations: list[str] = []
    for name in names:
        if not (root / Path(name)).exists():
            continue
        reason = source_violation(name)
        if reason is None:
            try:
                content = (root / Path(name)).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                content = ""
            reason = source_content_violation(name, content)
        if reason:
            violations.append(f"{name}: {reason}")
    return sorted(violations, key=str.casefold)


def _unsafe_archive_name(name: str) -> bool:
    normalized = name.replace("\\", "/")
    path = PurePosixPath(normalized)
    return (
        path.is_absolute()
        or bool(re.match(r"^[A-Za-z]:", normalized))
        or ".." in path.parts
    )


def scan_archive(path: Path) -> list[str]:
    violations: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                name = info.filename
                if _unsafe_archive_name(name):
                    violations.append(f"{name}: archive traversal or absolute path")
                    continue
                reason = artifact_violation(name)
                if reason:
                    violations.append(f"{name}: {reason}")
    except (OSError, zipfile.BadZipFile) as error:
        raise ValueError(f"cannot inspect archive {path}: {error}") from error
    return sorted(violations, key=str.casefold)


def scan_directory(path: Path) -> list[str]:
    violations: list[str] = []
    for entry in path.rglob("*"):
        name = entry.relative_to(path).as_posix()
        reason = artifact_violation(name)
        if reason:
            violations.append(f"{name}: {reason}")
    return sorted(violations, key=str.casefold)


def scan_artifact(path: Path) -> list[str]:
    if path.is_dir():
        return scan_directory(path)
    if path.is_file() and (path.suffix.casefold() in {".zip", ".apk"} or zipfile.is_zipfile(path)):
        return scan_archive(path)
    raise ValueError(f"artifact must be a directory, ZIP, or APK: {path}")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    source = subparsers.add_parser("source", help="scan Git-tracked source files")
    source.add_argument("root", nargs="?", type=Path, default=Path.cwd())
    artifact = subparsers.add_parser("artifact", help="scan release directories or archives")
    artifact.add_argument("paths", nargs="+", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.mode == "source":
            violations = scan_source(args.root.resolve())
        else:
            violations = []
            for path in args.paths:
                violations.extend(f"{path}: {item}" for item in scan_artifact(path))
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"runtime boundary scan failed: {error}", file=sys.stderr)
        return 2

    if violations:
        print("Forbidden runtime assets found:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        return 1
    print(f"Runtime boundary {args.mode} scan passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
