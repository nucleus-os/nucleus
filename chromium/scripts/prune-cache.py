#!/usr/bin/env python3
"""Apply the bounded on-disk retention policy after a successful build."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil


IDENTITY = re.compile(r"^[0-9a-f]{24}$")
RUN_DIRECTORY = re.compile(
    r"^[0-9]{8}T[0-9]{6}\.[0-9]+Z-[0-9]+-(doctor|bootstrap|build|test|install)$"
)


def current_name(link: Path) -> str | None:
    if not link.is_symlink():
        return None
    return (link.parent / link.readlink()).resolve().name


def prune_generations(root: Path, current: str | None, retain: int) -> list[Path]:
    if not root.is_dir() or root.is_symlink():
        return []
    candidates = [
        path
        for path in root.iterdir()
        if path.is_dir() and not path.is_symlink() and IDENTITY.fullmatch(path.name)
    ]
    newest = sorted(candidates, key=lambda path: path.stat().st_mtime_ns, reverse=True)
    keep = {path.name for path in newest[:retain]}
    if current:
        keep.add(current)
    removed: list[Path] = []
    for path in candidates:
        if path.name not in keep:
            shutil.rmtree(path)
            removed.append(path)
    return removed


def prune_run_logs(root: Path, current: str | None, retain: int) -> list[Path]:
    if not root.is_dir() or root.is_symlink():
        return []
    candidates = [
        path
        for path in root.iterdir()
        if path.is_dir()
        and not path.is_symlink()
        and RUN_DIRECTORY.fullmatch(path.name)
    ]
    newest = sorted(candidates, key=lambda path: path.stat().st_mtime_ns, reverse=True)
    keep = {path.name for path in newest[:retain]}
    if current:
        keep.add(current)
    removed: list[Path] = []
    for path in candidates:
        if path.name not in keep:
            shutil.rmtree(path)
            removed.append(path)
    return removed


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    cache = commands.add_parser("cache")
    cache.add_argument("--cache-root", type=Path, required=True)
    cache.add_argument("--source-generations", type=Path, required=True)
    cache.add_argument("--source-current", type=Path, required=True)
    cache.add_argument("--cef-dist", type=Path, required=True)
    cache.add_argument("--browser-dist", type=Path, required=True)
    cache.add_argument("--logs", type=Path, required=True)
    installed = commands.add_parser("installed")
    installed.add_argument("--runtime-root", type=Path, required=True)
    arguments = parser.parse_args()

    if arguments.command == "installed":
        runtime_root = arguments.runtime_root.resolve()
        removed = prune_generations(
            runtime_root / "generations",
            current_name(runtime_root / "current"),
            retain=2,
        )
        for path in removed:
            print(f"removed stale installed browser generation: {path}")
        if not removed:
            print("Installed browser generation retention is already satisfied")
        return 0

    cache_root = arguments.cache_root.resolve()
    for path in (
        arguments.source_generations,
        arguments.cef_dist,
        arguments.browser_dist,
        arguments.logs,
    ):
        try:
            path.resolve(strict=False).relative_to(cache_root)
        except ValueError as error:
            raise ValueError(f"refusing to prune outside {cache_root}: {path}") from error

    removed: list[Path] = []
    removed += prune_generations(
        arguments.source_generations,
        current_name(arguments.source_current),
        retain=1,
    )
    removed += prune_generations(
        arguments.cef_dist / "releases",
        current_name(arguments.cef_dist / "current-release"),
        retain=2,
    )
    removed += prune_generations(
        arguments.browser_dist / "generations",
        current_name(arguments.browser_dist / "current"),
        retain=2,
    )
    removed += prune_run_logs(
        arguments.logs / "runs",
        current_name(arguments.logs / "latest"),
        retain=50,
    )
    for path in removed:
        print(f"removed stale Chromium cache generation: {path}")
    if not removed:
        print("Chromium cache retention is already satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
