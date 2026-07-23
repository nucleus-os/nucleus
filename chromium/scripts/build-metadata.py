#!/usr/bin/env python3
"""Content identities for prepared Chromium sources and product outputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = 1
PATCH_DIRECTORIES = (
    "chromium/patches/common",
    "cef/patches",
    "chromium/patches/browser",
    "chromium/patches/dawn",
)


class MetadataError(RuntimeError):
    pass


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def patch_inventory(workspace: Path) -> list[dict[str, str]]:
    inventory: list[dict[str, str]] = []
    for relative_directory in PATCH_DIRECTORIES:
        directory = workspace / relative_directory
        for patch in sorted(directory.glob("*.patch")):
            inventory.append(
                {
                    "path": patch.relative_to(workspace).as_posix(),
                    "sha256": sha256_file(patch),
                }
            )
    if not inventory:
        raise MetadataError("the Chromium/CEF patch stack is empty")
    return inventory


def source_inputs(
    workspace: Path,
    cef_branch: str,
    cef_checkout: str,
    chromium_version: str,
    chromium_checkout: str,
    depot_tools_revision: str,
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "cef_branch": cef_branch,
        "cef_checkout": cef_checkout,
        "chromium_version": chromium_version,
        "chromium_checkout": chromium_checkout,
        "depot_tools_revision": depot_tools_revision,
        "automate_git_url": (
            "https://raw.githubusercontent.com/chromiumembedded/cef/"
            f"{cef_checkout}/tools/automate/automate-git.py"
        ),
        "patches": patch_inventory(workspace),
    }


def source_identifier(inputs: dict[str, Any]) -> str:
    return sha256_bytes(canonical_bytes(inputs))[:24]


def run_text(arguments: list[str], directory: Path | None = None) -> str:
    try:
        return subprocess.run(
            arguments,
            cwd=directory,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        stderr = getattr(error, "stderr", "")
        detail = stderr.strip() if isinstance(stderr, str) else ""
        raise MetadataError(
            f"command failed: {shlex.join(arguments)}"
            + (f": {detail}" if detail else "")
        ) from error


def git_revision(repository: Path) -> str:
    return run_text(["git", "rev-parse", "HEAD"], repository)


def git_diff_sha256(repository: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "diff", "--binary", "HEAD", "--"],
            cwd=repository,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise MetadataError(f"could not inspect prepared source: {repository}") from error
    return sha256_bytes(result.stdout)


def git_untracked_inventory(repository: Path) -> list[dict[str, str]]:
    try:
        result = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            cwd=repository,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise MetadataError(f"could not inspect untracked source: {repository}") from error
    inventory: list[dict[str, str]] = []
    for encoded in sorted(value for value in result.stdout.split(b"\0") if value):
        relative = os.fsdecode(encoded)
        source = repository / relative
        if not source.is_file() or source.is_symlink():
            raise MetadataError(f"unsupported untracked source input: {source}")
        inventory.append(
            {
                "path": relative,
                "mode": f"{source.stat().st_mode & 0o7777:04o}",
                "sha256": sha256_file(source),
            }
        )
    return inventory


def require_revision(repository: Path, expected: str, description: str) -> str:
    actual = git_revision(repository)
    if actual != expected:
        raise MetadataError(
            f"{description} revision mismatch: expected {expected}, found {actual}"
        )
    return actual


def build_source_manifest(
    workspace: Path,
    source_root: Path,
    depot_tools: Path,
    inputs: dict[str, Any],
) -> dict[str, Any]:
    chromium = source_root / "chromium/src"
    cef = chromium / "cef"
    dawn = chromium / "third_party/dawn"
    automate = source_root / "automate-git.py"
    for required in (chromium, cef, dawn, depot_tools, automate):
        if not required.exists():
            raise MetadataError(f"prepared source input is missing: {required}")

    chromium_revision = require_revision(
        chromium, str(inputs["chromium_checkout"]), "Chromium"
    )
    cef_revision = require_revision(
        cef, str(inputs["cef_checkout"]), "CEF"
    )
    depot_revision = require_revision(
        depot_tools, str(inputs["depot_tools_revision"]), "depot_tools"
    )

    manifest: dict[str, Any] = {
        "schema": SCHEMA,
        "source_id": source_identifier(inputs),
        "inputs": inputs,
        "revisions": {
            "chromium": chromium_revision,
            "cef": cef_revision,
            "dawn": git_revision(dawn),
            "depot_tools": depot_revision,
        },
        "working_diffs": {
            "chromium": git_diff_sha256(chromium),
            "cef": git_diff_sha256(cef),
            "dawn": git_diff_sha256(dawn),
        },
        "untracked_files": {
            "chromium": git_untracked_inventory(chromium),
            "cef": git_untracked_inventory(cef),
            "dawn": git_untracked_inventory(dawn),
        },
        "automate_git_sha256": sha256_file(automate),
    }
    manifest["manifest_sha256"] = sha256_bytes(canonical_bytes(manifest))
    return manifest


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(value, destination, indent=2, sort_keys=True)
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MetadataError(f"could not read build metadata: {path}: {error}") from error
    if not isinstance(value, dict):
        raise MetadataError(f"build metadata is not an object: {path}")
    return value


def normalized_gn_arguments(path: Path) -> list[str]:
    arguments: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line and not line.startswith("#"):
            arguments.append(line)
    return sorted(arguments)


def optional_profile(path: Path) -> dict[str, str] | None:
    if not path.is_file():
        return None
    return {"name": path.name, "sha256": sha256_file(path)}


def build_product_manifest(
    product: str,
    source_manifest_path: Path,
    source_root: Path,
    gn_arguments_path: Path,
) -> dict[str, Any]:
    source_manifest = read_json(source_manifest_path)
    chromium = source_root / "chromium/src"
    clang = chromium / "third_party/llvm-build/Release+Asserts/bin/clang"
    if not clang.is_file():
        raise MetadataError(f"Chromium clang is missing: {clang}")
    if not gn_arguments_path.is_file():
        raise MetadataError(f"GN arguments are missing: {gn_arguments_path}")

    pgo_descriptor = chromium / "chrome/build/linux.pgo.txt"
    pgo: dict[str, str] | None = None
    if pgo_descriptor.is_file():
        name = pgo_descriptor.read_text(encoding="utf-8").strip()
        if name and "/" not in name:
            pgo = optional_profile(chromium / "chrome/build/pgo_profiles" / name)
    v8_pgo = optional_profile(
        chromium / "v8/tools/builtins-pgo/profiles/x64.profile"
    )
    clang_version = run_text([str(clang), "--version"]).splitlines()[0]
    manifest: dict[str, Any] = {
        "schema": SCHEMA,
        "product": product,
        "source_id": source_manifest.get("source_id"),
        "source_manifest_sha256": source_manifest.get("manifest_sha256"),
        "gn_arguments": normalized_gn_arguments(gn_arguments_path),
        "clang": {
            "version": clang_version,
            "sha256": sha256_file(clang),
        },
        "pgo": pgo,
        "v8_builtins_pgo": v8_pgo,
    }
    manifest["build_id"] = sha256_bytes(canonical_bytes(manifest))[:24]
    return manifest


def common_source_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--cef-branch", required=True)
    parser.add_argument("--cef-checkout", required=True)
    parser.add_argument("--chromium-version", required=True)
    parser.add_argument("--chromium-checkout", required=True)
    parser.add_argument("--depot-tools-revision", required=True)


def expected_inputs(arguments: argparse.Namespace) -> dict[str, Any]:
    return source_inputs(
        arguments.workspace.resolve(),
        arguments.cef_branch,
        arguments.cef_checkout,
        arguments.chromium_version,
        arguments.chromium_checkout,
        arguments.depot_tools_revision,
    )


def verify_equal(actual: dict[str, Any], expected: dict[str, Any], label: str) -> None:
    if actual != expected:
        raise MetadataError(f"{label} does not match the current build inputs")


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    source_id_parser = commands.add_parser("source-id")
    common_source_arguments(source_id_parser)

    for name in ("write-source", "verify-source"):
        child = commands.add_parser(name)
        common_source_arguments(child)
        child.add_argument("--source-root", type=Path, required=True)
        child.add_argument("--depot-tools", type=Path, required=True)
        child.add_argument("--manifest", type=Path, required=True)

    for name in ("write-build", "verify-build"):
        child = commands.add_parser(name)
        child.add_argument("--product", choices=("cef", "browser"), required=True)
        child.add_argument("--source-root", type=Path, required=True)
        child.add_argument("--source-manifest", type=Path, required=True)
        child.add_argument("--gn-args", type=Path, required=True)
        child.add_argument("--manifest", type=Path, required=True)

    build_id_parser = commands.add_parser("build-id")
    build_id_parser.add_argument("--manifest", type=Path, required=True)

    arguments = parser.parse_args()
    if arguments.command == "source-id":
        print(source_identifier(expected_inputs(arguments)))
        return 0

    if arguments.command in ("write-source", "verify-source"):
        manifest = build_source_manifest(
            arguments.workspace.resolve(),
            arguments.source_root.resolve(),
            arguments.depot_tools.resolve(),
            expected_inputs(arguments),
        )
        if arguments.command == "write-source":
            atomic_write_json(arguments.manifest, manifest)
        else:
            verify_equal(read_json(arguments.manifest), manifest, "source manifest")
        print(manifest["source_id"])
        return 0

    if arguments.command in ("write-build", "verify-build"):
        manifest = build_product_manifest(
            arguments.product,
            arguments.source_manifest.resolve(),
            arguments.source_root.resolve(),
            arguments.gn_args.resolve(),
        )
        if arguments.command == "write-build":
            atomic_write_json(arguments.manifest, manifest)
        else:
            verify_equal(read_json(arguments.manifest), manifest, "build manifest")
        print(manifest["build_id"])
        return 0

    manifest = read_json(arguments.manifest)
    build_id = manifest.get("build_id")
    if not isinstance(build_id, str) or not build_id:
        raise MetadataError(f"build_id is missing from {arguments.manifest}")
    print(build_id)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MetadataError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
