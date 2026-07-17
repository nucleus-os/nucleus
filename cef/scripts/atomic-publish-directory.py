#!/usr/bin/env python3

"""Atomically publish a prepared directory over an existing directory.

Both paths must be sibling directories on Linux. If the destination exists,
renameat2(RENAME_EXCHANGE) swaps the complete trees in one filesystem
operation; the displaced old tree is then removed from the prepared path.
"""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import shutil
import sys


AT_FDCWD = -100
RENAME_EXCHANGE = 1 << 1


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def exchange(left: Path, right: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise RuntimeError("libc does not expose renameat2")
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        AT_FDCWD,
        os.fsencode(left),
        AT_FDCWD,
        os.fsencode(right),
        RENAME_EXCHANGE,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), f"{left} <-> {right}")


def remove_tree(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def publish(prepared: Path, destination: Path) -> None:
    prepared = prepared.absolute()
    destination = destination.absolute()
    if prepared.parent != destination.parent:
        raise ValueError("prepared and destination must be sibling paths")
    if prepared == destination:
        raise ValueError("prepared and destination must differ")
    if not prepared.is_dir() or prepared.is_symlink():
        raise ValueError(f"prepared path is not a real directory: {prepared}")

    parent = destination.parent
    if destination.exists() or destination.is_symlink():
        if not destination.is_dir() or destination.is_symlink():
            raise ValueError(
                f"destination is not a replaceable directory: {destination}"
            )
        exchange(prepared, destination)
        fsync_directory(parent)
        # The old destination now occupies the prepared path. Publication has
        # already succeeded, so cleanup failure must not roll it back.
        remove_tree(prepared)
    else:
        os.rename(prepared, destination)
    fsync_directory(parent)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("prepared", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    try:
        publish(arguments.prepared, arguments.destination)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"atomic directory publication failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
