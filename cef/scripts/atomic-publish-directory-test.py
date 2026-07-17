#!/usr/bin/env python3

"""Regression coverage for atomic-publish-directory.py."""

from pathlib import Path
import subprocess
import sys
import tempfile


def run(script: Path, prepared: Path, destination: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), str(prepared), str(destination)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def main() -> int:
    script = Path(__file__).with_name("atomic-publish-directory.py")
    with tempfile.TemporaryDirectory(prefix="nucleus-cef-publish-") as directory:
        root = Path(directory)

        prepared = root / "prepared"
        destination = root / "destination"
        prepared.mkdir()
        destination.mkdir()
        (prepared / "new").write_text("new", encoding="utf-8")
        (destination / "old").write_text("old", encoding="utf-8")
        replaced = run(script, prepared, destination)
        if replaced.returncode != 0:
            sys.stderr.write(replaced.stderr)
            return 1
        if prepared.exists() or not (destination / "new").is_file() or (destination / "old").exists():
            print("existing destination was not atomically replaced", file=sys.stderr)
            return 1

        first = root / "first"
        first_destination = root / "first-destination"
        first.mkdir()
        (first / "complete").write_text("complete", encoding="utf-8")
        published = run(script, first, first_destination)
        if published.returncode != 0:
            sys.stderr.write(published.stderr)
            return 1
        if first.exists() or not (first_destination / "complete").is_file():
            print("first publication did not move the complete tree", file=sys.stderr)
            return 1

        left = root / "left"
        right = root / "right"
        invalid_prepared = left / "prepared"
        invalid_destination = right / "destination"
        invalid_prepared.mkdir(parents=True)
        invalid_destination.mkdir(parents=True)
        (invalid_prepared / "new").write_text("new", encoding="utf-8")
        (invalid_destination / "old").write_text("old", encoding="utf-8")
        rejected = run(script, invalid_prepared, invalid_destination)
        if rejected.returncode == 0:
            print("non-sibling publication was not rejected", file=sys.stderr)
            return 1
        if not (invalid_prepared / "new").is_file() or not (invalid_destination / "old").is_file():
            print("failed publication modified an input tree", file=sys.stderr)
            return 1

        symlink_prepared = root / "symlink-prepared"
        real_destination = root / "real-destination"
        symlink_destination = root / "symlink-destination"
        symlink_prepared.mkdir()
        real_destination.mkdir()
        symlink_destination.symlink_to(real_destination.name)
        rejected_symlink = run(script, symlink_prepared, symlink_destination)
        if rejected_symlink.returncode == 0 or not symlink_destination.is_symlink():
            print("symlink destination was not safely rejected", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
