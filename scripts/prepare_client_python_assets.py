#!/usr/bin/env python3
"""Prepare Python source assets for the HakureiTerminal Flutter app.

The project is now HakureiTerminal-first. GensokyoAI is expected to be an
embedded source component selected by this project, not the old repository-root
fork package. This script copies only runtime assets that already exist in this
repository into ``assets/python``. It does not bundle CPython; release packaging
adds a platform-specific runtime later.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TARGET = ROOT / "assets" / "python"
DEFAULT_BACKEND_DIR = ROOT / "backend" / "GensokyoAI"

COPY_ITEMS = [
    "characters",
    "config",
    "bridge_main.py",
    "requirements.txt",
]
IGNORE_NAMES = {
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache",
}


def ignore_patterns(directory: str, names: list[str]) -> set[str]:
    ignored = {name for name in names if name in IGNORE_NAMES}
    ignored.update(name for name in names if name.endswith((".pyc", ".pyo")))
    return ignored


def copy_item(source: Path, target: Path) -> None:
    if source.is_dir():
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target, ignore=ignore_patterns)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def copy_backend(backend_dir: Path, target: Path) -> None:
    backend_dir = backend_dir.resolve()
    if not backend_dir.exists():
        raise FileNotFoundError(
            "Embedded GensokyoAI backend source does not exist: "
            f"{backend_dir}\n"
            "Place the selected backend snapshot there, or pass --backend-dir."
        )
    if not backend_dir.is_dir():
        raise NotADirectoryError(f"Backend source must be a directory: {backend_dir}")
    copy_item(backend_dir, target / "GensokyoAI")


def prepare(target: Path, backend_dir: Path = DEFAULT_BACKEND_DIR, clean: bool = True) -> None:
    target = target.resolve()
    if clean and target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True, exist_ok=True)

    copy_backend(backend_dir, target)

    for item in COPY_ITEMS:
        source = ROOT / item
        if not source.exists():
            raise FileNotFoundError(f"Required source asset does not exist: {source}")
        copy_item(source, target / item)

    readme = target / "README.txt"
    readme.write_text(
        "This directory contains HakureiTerminal Python bridge source assets.\n"
        "GensokyoAI is copied from this repository's embedded backend source.\n"
        "It intentionally does not contain a CPython runtime yet.\n"
        "Release builds must provide a bundled runtime and must not call system Python.\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare Flutter Python assets")
    parser.add_argument("--target", type=Path, default=DEFAULT_TARGET)
    parser.add_argument("--backend-dir", type=Path, default=DEFAULT_BACKEND_DIR)
    parser.add_argument("--no-clean", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    prepare(args.target, backend_dir=args.backend_dir, clean=not args.no_clean)
    print(f"Prepared Python assets at {args.target}")


if __name__ == "__main__":
    main()
