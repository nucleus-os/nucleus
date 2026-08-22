#!/usr/bin/env bash
set -euo pipefail

readonly repo="${AOSP_REPO_LAUNCHER:?}"
readonly source_inputs=/inputs/source-inputs
readonly expected_manifest="${AOSP_RESOLVED_MANIFEST:?}"
readonly expected_provenance="${AOSP_SOURCE_PROVENANCE:?}"
readonly resolved_manifest=/src/.nucleus/resolved-manifest.xml
readonly source_provenance=/src/.nucleus/source-provenance.json

validate_manifest_revisions() {
  python3 - "$expected_manifest" "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET

def projects(path):
    result = {}
    for project in ET.parse(path).getroot().findall("project"):
        key = (project.get("name"), project.get("path"))
        revision = project.get("revision")
        if not key[0] or not revision or key in result:
            raise SystemExit(f"invalid project entry in {path}: {key!r}")
        result[key] = revision
    return result

expected = projects(sys.argv[1])
actual = projects(sys.argv[2])
if expected == actual:
    raise SystemExit(0)

for key in sorted(expected.keys() - actual.keys())[:20]:
    print(f"missing project {key!r}", file=sys.stderr)
for key in sorted(actual.keys() - expected.keys())[:20]:
    print(f"unexpected project {key!r}", file=sys.stderr)
for key in sorted(expected.keys() & actual.keys()):
    if expected[key] != actual[key]:
        print(
            f"revision mismatch for {key!r}: "
            f"expected {expected[key]}, found {actual[key]}",
            file=sys.stderr,
        )
raise SystemExit(1)
PY
}

if [[ ! -f "$repo" \
    || ! -d "$source_inputs/.repo" \
    || ! -f "$expected_manifest" \
    || ! -f "$expected_provenance" ]]; then
  echo "error: AOSP source materialization inputs are incomplete" >&2
  exit 64
fi

mkdir -p /src/out

if [[ -d /src/.repo \
    && -f "$resolved_manifest" \
    && -f "$source_provenance" ]] \
    && cmp -s "$expected_manifest" "$resolved_manifest" \
    && cmp -s "$expected_provenance" "$source_provenance"; then
  current_manifest="$(mktemp)"
  trap 'rm -f "$current_manifest"' EXIT
  python3 "$repo" manifest --revision-as-HEAD >"$current_manifest"
  if ! validate_manifest_revisions "$current_manifest"; then
    echo "error: materialized AOSP revisions differ from the locked manifest" >&2
    exit 65
  fi
  python3 "$repo" forall --ignore-missing --jobs="$AOSP_SYNC_JOBS" -c \
    'test ! -e .git || test -z "$(git status --porcelain=v1 --untracked-files=normal)"'
else
  if [[ -n "$(find /src -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)" \
      && ! -d /src/.repo ]]; then
    echo "error: AOSP source volume is nonempty without Repo metadata" >&2
    exit 65
  fi
  if [[ ! -d /src/.repo ]]; then
    cp -a "$source_inputs/.repo" /src/.repo
  fi
  python3 "$repo" sync \
    --local-only \
    --no-manifest-update \
    --current-branch \
    --detach \
    --fail-fast \
    --force-checkout \
    --force-sync \
    --no-clone-bundle \
    --no-interleaved \
    --no-tags \
    --prune \
    --jobs-checkout="$AOSP_SYNC_JOBS"

  current_manifest="$(mktemp)"
  trap 'rm -f "$current_manifest"' EXIT
  python3 "$repo" manifest --revision-as-HEAD >"$current_manifest"
  if ! validate_manifest_revisions "$current_manifest"; then
    install -m 0644 "$current_manifest" /export/actual-resolved-manifest.xml
    echo "error: offline AOSP materialization differs from the locked manifest" >&2
    exit 65
  fi
  python3 "$repo" forall --ignore-missing --jobs="$AOSP_SYNC_JOBS" -c \
    'test ! -e .git || test -z "$(git status --porcelain=v1 --untracked-files=normal)"'
  mkdir -p /src/.nucleus /src/out
  install -m 0644 "$expected_manifest" "$resolved_manifest"
  install -m 0644 "$expected_provenance" "$source_provenance"
fi

rm -f /export/actual-resolved-manifest.xml
install -m 0644 "$resolved_manifest" /export/resolved-manifest.xml
install -m 0644 "$source_provenance" /export/source-provenance.json
