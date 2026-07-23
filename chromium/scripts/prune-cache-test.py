#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("prune-cache.py")
SPEC = importlib.util.spec_from_file_location("prune_cache", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
prune_cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prune_cache)


class PruneCacheTests(unittest.TestCase):
    def test_current_generation_is_never_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old = root / ("a" * 24)
            current = root / ("b" * 24)
            newest = root / ("c" * 24)
            old.mkdir()
            current.mkdir()
            newest.mkdir()
            removed = prune_cache.prune_generations(root, current.name, retain=1)
            self.assertTrue(current.exists())
            self.assertTrue(newest.exists())
            self.assertEqual(set(removed), {old})

    def test_non_identity_directories_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unrelated = root / "user-data"
            unrelated.mkdir()
            self.assertEqual(prune_cache.prune_generations(root, None, retain=1), [])
            self.assertTrue(unrelated.exists())

    def test_run_log_retention_ignores_unknown_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unknown = root / "user-data"
            unknown.mkdir()
            for index in range(3):
                (root / f"20260722T12000{index}.1Z-{index + 1}-build").mkdir()
            removed = prune_cache.prune_run_logs(root, None, retain=2)
            self.assertEqual(len(removed), 1)
            self.assertTrue(unknown.exists())

    def test_installed_command_retains_current_and_previous_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runtime_root = Path(temporary) / "nucleus-browser"
            generations = runtime_root / "generations"
            generations.mkdir(parents=True)
            identities = [f"{value:024x}" for value in range(3)]
            for index, identity in enumerate(identities):
                generation = generations / identity
                generation.mkdir()
                os.utime(generation, ns=(index + 1, index + 1))
            (runtime_root / "current").symlink_to(
                Path("generations") / identities[-1]
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "installed",
                    "--runtime-root",
                    str(runtime_root),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((generations / identities[0]).exists())
            self.assertTrue((generations / identities[1]).exists())
            self.assertTrue((generations / identities[2]).exists())

if __name__ == "__main__":
    unittest.main()
