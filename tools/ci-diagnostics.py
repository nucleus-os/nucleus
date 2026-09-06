#!/usr/bin/env python3
"""Bounded, credential-scrubbed CI evidence export; never invokes Collider."""

import datetime
import json
import os
import re
import stat
import sys
import time
from pathlib import Path

FILE_LIMIT = 8 * 1024 * 1024
BUNDLE_LIMIT = 128 * 1024 * 1024
FILE_COUNT_LIMIT = 512
CRASH_PROCESSES = {
    "collider", "swift-frontend", "swift-package-manager", "swift-package",
    "swift-build", "swift-nucleus-driver", "clang", "ld",
}
CRASH_FIELDS = {
    "procName", "procPath", "pid", "captureTime", "exception", "termination",
    "faultingThread", "threads", "usedImages", "lastExceptionBacktrace", "asi",
    "vmSummary", "translated", "cpuType", "osVersion",
}


def scrub(text):
    text = re.sub(r"(https?://)[^/\s@]+@", r"\1<redacted>@", text)
    text = re.sub(r"(?im)^(\s*(?:authorization|cookie)\s*:\s*)[^\r\n]+",
                  r"\1<redacted>", text)
    text = re.sub(r'(?i)("(?:authorization|cookie|credential|password|passwd|secret|token|api[-_]?key|access[-_]?key)"\s*:\s*")[^"]*',
                  r'\1<redacted>', text)
    text = re.sub(r"(?i)((?:credential|password|passwd|secret|token|api[-_]?key|access[-_]?key)=)[^\s&\"']+",
                  r"\1<redacted>", text)
    text = re.sub(r"(?i)(--(?:password|token|secret|api-key)\s+)(?:\"[^\"]*\"|'[^']*'|\S+)",
                  r"\1<redacted>", text)
    text = re.sub(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b",
                  "<redacted>", text)
    for name, value in os.environ.items():
        if len(value) >= 8 and re.search(r"(?i)(token|password|secret|credential|api_key)", name):
            text = text.replace(value, "<redacted>")
    return text


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def read_regular(path, limit=FILE_LIMIT, tail=False):
    """Open every path component without following links; never read devices."""
    path = Path(path).absolute()
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        child = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                        dir_fd=descriptor)
    finally:
        os.close(descriptor)
    with os.fdopen(child, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("not a regular file")
        truncated = metadata.st_size > limit
        if truncated and not tail:
            raise ValueError("structured file exceeds size limit")
        if truncated:
            stream.seek(-limit, os.SEEK_END)
        return stream.read(limit), truncated, metadata.st_mtime


class Bundle:
    def __init__(self, root):
        self.root = root
        self.size = 0
        self.files = []
        self.omissions = []

    def add(self, relative, data, truncated=False):
        data = scrub(data.decode("utf-8", errors="replace")).encode("utf-8")
        if len(data) > FILE_LIMIT:
            self.omissions.append({"file": relative, "reason": "scrubbed file exceeds size limit"})
            return
        if len(self.files) >= FILE_COUNT_LIMIT or self.size + len(data) > BUNDLE_LIMIT:
            self.omissions.append({"file": relative, "reason": "bundle limit"})
            return
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
        self.files.append({"file": relative, "bytes": len(data), "tailOnly": truncated})
        self.size += len(data)

    def copy(self, path, relative, tail=False):
        if len(self.files) >= FILE_COUNT_LIMIT or self.size >= BUNDLE_LIMIT:
            if not any(item["reason"] == "bundle limit" for item in self.omissions):
                self.omissions.append({"file": relative, "reason": "bundle limit"})
            return
        try:
            data, truncated, _ = read_regular(path, tail=tail)
            self.add(relative, data, truncated)
        except (OSError, ValueError) as error:
            self.omissions.append({"file": relative, "reason": type(error).__name__})


def collect_runs(bundle, runs_root, context):
    summaries = []
    if not runs_root.is_dir():
        bundle.omissions.append({"file": "runs", "reason": "run store unavailable"})
        return summaries
    for directory in sorted(runs_root.iterdir()):
        if directory.is_symlink() or not directory.is_dir():
            continue
        try:
            data, _, _ = read_regular(directory / "manifest.json")
            manifest = json.loads(data)
            provenance = manifest.get("provenance") or {}
            if (provenance.get("sourceAuthority") != "protected-main"
                    or provenance.get("producerTrustDomain") != "nucleus-builder"
                    or provenance.get("sourceCommit") != context["revision"]
                    or not context["started"] <= timestamp(manifest["startedAt"]) <= context["finished"]):
                continue
        except (OSError, ValueError, KeyError, TypeError) as error:
            if context["started"] <= directory.stat().st_mtime <= context["finished"]:
                bundle.omissions.append({"file": "runs/" + directory.name + "/manifest.json",
                                         "reason": type(error).__name__})
            continue
        prefix = "runs/" + directory.name
        bundle.add(prefix + "/manifest.json", data)
        for name in ("events.jsonl", "run.log"):
            bundle.copy(directory / name, prefix + "/" + name, tail=True)
        stages = directory / "stages"
        if stages.is_dir() and not stages.is_symlink():
            for path in sorted(stages.glob("*.log")):
                bundle.copy(path, prefix + "/stages/" + path.name, tail=True)
        summaries.append({key: manifest.get(key) for key in (
            "runID", "status", "failedTask", "planningDurationNanoseconds",
            "selectedInputHashingDurationNanoseconds", "swiftPMInvocationCount",
            "executionDurationNanoseconds")})
    return summaries


def collect_crashes(bundle, reports_root, context, allowed_pids=None, prefix="crashes"):
    found = 0
    if not reports_root.is_dir():
        bundle.omissions.append({"file": prefix, "reason": "diagnostic directory unavailable"})
        return found
    try:
        candidates = sorted(reports_root.glob("*.ips"))
    except OSError as error:
        bundle.omissions.append({"file": prefix, "reason": type(error).__name__})
        return found
    for path in candidates:
        if not any(path.name.startswith(name + "-") for name in CRASH_PROCESSES):
            continue
        try:
            data, _, modified = read_regular(path)
            if not context["started"] <= modified <= context["finished"]:
                continue
            text = data.decode("utf-8")
            header, offset = json.JSONDecoder().raw_decode(text)
            body = json.loads(text[offset:]) if text[offset:].strip() else header
            if body.get("procName") not in CRASH_PROCESSES:
                continue
            if allowed_pids is not None and (body.get("procName") != "collider" or body.get("pid") not in allowed_pids):
                continue
            captured = timestamp(body.get("captureTime") or header["timestamp"])
            if not context["started"] <= captured <= context["finished"]:
                continue
            # Exclude machine identifiers and unrelated report metadata. Keep
            # symbolication inputs and fault details, never process memory.
            selected = {key: body[key] for key in CRASH_FIELDS if key in body}
            bundle.add(prefix + "/" + path.stem + ".json",
                       json.dumps(selected, indent=2, sort_keys=True).encode())
            found += 1
        except (OSError, ValueError, KeyError, TypeError) as error:
            bundle.omissions.append({"file": prefix + "/" + path.name, "reason": type(error).__name__})
    return found


def location():
    run = os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    revision = os.environ["NUCLEUS_PRODUCT_SOURCE_COMMIT"]
    if not run.isdecimal() or not attempt.isdecimal() or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid CI identity")
    return Path(os.environ["RUNNER_TEMP"]).resolve() / ("collider-diagnostics-" + run + "-" + attempt), revision


def main():
    root, revision = location()
    if sys.argv[1:] == ["begin"]:
        root.mkdir(mode=0o700)
        context = {"started": time.time(), "revision": revision,
                   "run": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"]}
        (root / "context.json").write_text(json.dumps(context))
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("path=" + str(root / "bundle") + "\n")
        return
    if sys.argv[1:] != ["collect"]:
        raise ValueError("expected begin or collect")
    context = json.loads(read_regular(root / "context.json")[0])
    if context["revision"] != revision:
        raise ValueError("attempt revision changed")
    # macOS crash reports are asynchronous. This bounded grace period is only
    # paid after failure, and no execution lease is acquired by this collector.
    if os.environ.get("DIAGNOSTIC_JOB_STATUS") == "failure":
        time.sleep(10)
    context["finished"] = time.time()
    context["jobStatus"] = os.environ.get("DIAGNOSTIC_JOB_STATUS", "unknown")
    bundle = Bundle(root / "bundle")
    bundle.root.mkdir(mode=0o700)
    context["crashReports"] = collect_crashes(bundle, Path.home() / "Library/Logs/DiagnosticReports", context)
    context["runs"] = collect_runs(bundle, Path("/Library/Nucleus/Collider/logs/runs/runs"), context)
    # Background/privileged processes may be reported system-wide rather than
    # under the account's home. Never collect other users' crashes: require
    # Collider's exact PID from an already-selected run and its capture time.
    pids = {int(item["runID"].rsplit("-", 1)[-1]) for item in context["runs"]
            if isinstance(item.get("runID"), str) and item["runID"].rsplit("-", 1)[-1].isdigit()}
    if pids:
        context["crashReports"] += collect_crashes(bundle, Path("/Library/Logs/DiagnosticReports"),
                                                   context, allowed_pids=pids, prefix="system-crashes")
    context["files"] = bundle.files
    context["omissions"] = bundle.omissions
    (bundle.root / "index.json").write_text(scrub(json.dumps(context, indent=2, sort_keys=True)))
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write("\n### Collider diagnostics\n\n"
                     + str(len(context["runs"])) + " run records; "
                     + str(context["crashReports"]) + " crash reports. "
                     + "Download the diagnostic artifact for this attempt. "
                     + "`index.json` records timing, omissions, and log truncation.\n")


if __name__ == "__main__":
    main()
