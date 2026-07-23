#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("build-metadata.py")
SPEC = importlib.util.spec_from_file_location("build_metadata", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
build_metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_metadata)


class BuildMetadataTests(unittest.TestCase):
    def make_workspace(self, root: Path) -> Path:
        workspace = root / "workspace"
        for directory in build_metadata.PATCH_DIRECTORIES:
            path = workspace / directory
            path.mkdir(parents=True)
            (path / "0001-test.patch").write_text(
                f"patch for {directory}\n", encoding="utf-8"
            )
        return workspace

    def test_source_identity_changes_with_patch_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = self.make_workspace(Path(temporary))
            first = build_metadata.source_inputs(
                workspace, "1", "a" * 40, "1.2.3.4", "c" * 40, "b" * 40
            )
            first_id = build_metadata.source_identifier(first)
            patch = workspace / "cef/patches/0001-test.patch"
            patch.write_text("changed\n", encoding="utf-8")
            second = build_metadata.source_inputs(
                workspace, "1", "a" * 40, "1.2.3.4", "c" * 40, "b" * 40
            )
            self.assertNotEqual(first_id, build_metadata.source_identifier(second))

    def test_build_identity_changes_with_gn_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            clang = source / "chromium/src/third_party/llvm-build/Release+Asserts/bin/clang"
            clang.parent.mkdir(parents=True)
            clang.write_text("#!/bin/sh\necho 'clang version test'\n", encoding="utf-8")
            clang.chmod(clang.stat().st_mode | stat.S_IXUSR)
            source_manifest = root / "source.json"
            build_metadata.atomic_write_json(
                source_manifest,
                {"source_id": "source", "manifest_sha256": "manifest"},
            )
            gn_args = root / "args.gn"
            gn_args.write_text("is_official_build=true\n", encoding="utf-8")
            first = build_metadata.build_product_manifest(
                "browser", source_manifest, source, gn_args
            )
            gn_args.write_text(
                "is_official_build=true\nuse_thin_lto=true\n", encoding="utf-8"
            )
            second = build_metadata.build_product_manifest(
                "browser", source_manifest, source, gn_args
            )
            self.assertNotEqual(first["build_id"], second["build_id"])

    def test_atomic_json_has_deterministic_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "nested/manifest.json"
            build_metadata.atomic_write_json(destination, {"b": 2, "a": 1})
            self.assertEqual(
                json.loads(destination.read_text(encoding="utf-8")),
                {"a": 1, "b": 2},
            )
            self.assertEqual(list(destination.parent.glob("*.tmp")), [])

    def test_untracked_source_files_participate_in_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            subprocess.run(["git", "init", "-q", repository], check=True)
            source = repository / "new-source.cc"
            source.write_text("first\n", encoding="utf-8")
            first = build_metadata.git_untracked_inventory(repository)
            source.write_text("second\n", encoding="utf-8")
            second = build_metadata.git_untracked_inventory(repository)
            self.assertNotEqual(first, second)
            source.chmod(source.stat().st_mode | stat.S_IXUSR)
            third = build_metadata.git_untracked_inventory(repository)
            self.assertNotEqual(second, third)


if __name__ == "__main__":
    unittest.main()
