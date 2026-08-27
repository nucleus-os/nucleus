#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from urllib.parse import unquote


DOCUMENT_SUFFIXES = {".md", ".txt"}
KEBAB_CASE_DOCUMENT = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*\.(?:md|txt)$")
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")


def repository_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return Path(result.stdout.strip()).resolve()


def repository_paths(root: Path) -> list[Path]:
    result = subprocess.run(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [Path(value.decode()) for value in result.stdout.split(b"\0") if value]


def relative_link_target(raw_target: str) -> str | None:
    target = raw_target.strip()
    if not target or target.startswith(("#", "http://", "https://", "mailto:")):
        return None
    if target.startswith("<") and ">" in target:
        target = target[1 : target.index(">")]
    else:
        target = target.split(maxsplit=1)[0]
    return unquote(target.split("#", maxsplit=1)[0]) or None


def main() -> int:
    root = repository_root()
    paths = repository_paths(root)
    failures: list[str] = []
    documents: list[Path] = []

    for path in paths:
        if not (root / path).exists():
            continue
        parts = path.parts
        if "docs" in parts and parts[0] != "docs":
            failures.append(f"documentation must live under root docs/: {path}")
        if path.name == "ARCHITECTURE.md" and parts[0] != "docs":
            failures.append(f"architecture document must live under root docs/: {path}")
        if parts and parts[0] == "docs" and path.suffix.lower() in DOCUMENT_SUFFIXES:
            documents.append(path)

    names: dict[str, list[Path]] = defaultdict(list)
    for path in documents:
        names[path.name].append(path)
        if path.name != "README.md" and not KEBAB_CASE_DOCUMENT.fullmatch(path.name):
            failures.append(f"documentation filename is not kebab-case: {path}")
    for name, matching_paths in sorted(names.items()):
        if len(matching_paths) > 1:
            joined = ", ".join(str(path) for path in matching_paths)
            failures.append(f"documentation filename is not globally unique ({name}): {joined}")

    for path in documents:
        if path.suffix.lower() != ".md":
            continue
        absolute = root / path
        for line_number, line in enumerate(absolute.read_text().splitlines(), start=1):
            for raw_target in MARKDOWN_LINK.findall(line):
                target = relative_link_target(raw_target)
                if target is None:
                    continue
                resolved = (absolute.parent / target).resolve()
                if not resolved.exists():
                    failures.append(
                        f"broken relative Markdown link: {path}:{line_number}: {raw_target}"
                    )

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1

    print(f"documentation layout valid ({len(documents)} documents)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
