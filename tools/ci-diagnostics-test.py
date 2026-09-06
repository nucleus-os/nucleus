#!/usr/bin/env python3
"""Collector contract tests, executed by CI without building Collider."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("diagnostics", Path(__file__).with_name("ci-diagnostics.py"))
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bundle = diagnostics.Bundle(self.root / "bundle")
        self.context = {"revision": "a" * 40, "started": 100, "finished": 200}

    def test_only_current_attempt_revision_is_exported_even_if_interrupted(self):
        for name, revision, start in (("selected", "a" * 40, 120), ("old", "a" * 40, 90), ("other", "b" * 40, 130)):
            directory = self.root / "runs" / name
            directory.mkdir(parents=True)
            (directory / "manifest.json").write_text(json.dumps({
                "runID": name, "status": "running", "startedAt": "1970-01-01T00:%02d:%02dZ" % divmod(start, 60),
                "provenance": {"sourceCommit": revision, "sourceAuthority": "protected-main",
                               "producerTrustDomain": "nucleus-builder"},
                "selectedInputHashingDurationNanoseconds": 42,
            }))
            (directory / "run.log").write_text("diagnostic output")
            (directory / "events.jsonl").write_text("{}\n")
        result = diagnostics.collect_runs(self.bundle, self.root / "runs", self.context)
        self.assertEqual([item["runID"] for item in result], ["selected"])
        self.assertEqual(result[0]["selectedInputHashingDurationNanoseconds"], 42)
        self.assertFalse((self.bundle.root / "runs/old").exists())

    def test_crash_projection_retains_stack_but_excludes_machine_identifiers(self):
        reports = self.root / "reports"
        reports.mkdir()
        for name, process, captured in (("collider-selected", "collider", 120),
                                        ("collider-stale", "collider", 90),
                                        ("collider-unrelated", "Other", 120)):
            path = reports / (name + ".ips")
            path.write_text(json.dumps({"timestamp": "1970-01-01T00:02:00Z"}) + "\n" + json.dumps({
                "procName": process, "captureTime": "1970-01-01T00:%02d:%02dZ" % divmod(captured, 60),
                "threads": [{"frames": [{"symbol": "failingFunction"}]}],
                "exception": {"type": "EXC_BAD_ACCESS"}, "crashReporterKey": "private-machine-id",
            }))
            os.utime(path, (150, 150))
        self.assertEqual(diagnostics.collect_crashes(self.bundle, reports, self.context), 1)
        text = (self.bundle.root / "crashes/collider-selected.json").read_text()
        self.assertIn("failingFunction", text)
        self.assertNotIn("private-machine-id", text)

    def test_symlink_files_and_parent_directories_are_rejected(self):
        secret = self.root / "secret"
        secret.write_text("do not export")
        link = self.root / "link"
        link.symlink_to(secret)
        self.bundle.copy(link, "file.log")
        folder = self.root / "linked-parent"
        folder.symlink_to(self.root, target_is_directory=True)
        self.bundle.copy(folder / "secret", "parent.log")
        self.assertEqual(self.bundle.files, [])
        self.assertEqual(len(self.bundle.omissions), 2)

    def test_system_reports_require_exact_collider_pid(self):
        reports = self.root / "system-reports"
        reports.mkdir()
        for pid, process in ((42, "collider"), (43, "collider"), (42, "clang")):
            path = reports / (process + "-" + str(pid) + ".ips")
            path.write_text(json.dumps({"procName": process, "pid": pid,
                                       "captureTime": "1970-01-01T00:02:00Z"}))
            os.utime(path, (150, 150))
        self.assertEqual(diagnostics.collect_crashes(self.bundle, reports, self.context,
                                                     allowed_pids={42}, prefix="system-crashes"), 1)
        self.assertEqual([item["file"] for item in self.bundle.files], ["system-crashes/collider-42.json"])

    def test_log_tail_and_structured_file_size_limits_are_explicit(self):
        path = self.root / "large"
        path.write_bytes(b"1234567890")
        data, truncated, _ = diagnostics.read_regular(path, limit=4, tail=True)
        self.assertEqual(data, b"7890")
        self.assertTrue(truncated)
        with self.assertRaises(ValueError):
            diagnostics.read_regular(path, limit=4)
        with patch.object(diagnostics, "BUNDLE_LIMIT", 4):
            self.bundle.add("first.log", b"1234")
            self.bundle.add("second.log", b"5")
        self.assertEqual(len(self.bundle.files), 1)
        self.assertEqual(self.bundle.omissions[0]["reason"], "bundle limit")

    def test_credentials_are_scrubbed_before_any_export(self):
        with patch.dict(os.environ, {"TEST_SECRET": "known-sensitive-value"}):
            result = diagnostics.scrub(
                'https://user:pass@example.com/path?token=query-secret\n'
                'Authorization: Bearer auth-secret\n'
                '{"token":"json-secret"}\n--password cli-secret\nknown-sensitive-value')
        for secret in ("user:pass", "query-secret", "auth-secret", "json-secret", "cli-secret", "known-sensitive-value"):
            self.assertNotIn(secret, result)
        self.assertIn("example.com/path", result)


if __name__ == "__main__":
    unittest.main()
