#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: hydrate-aosp-source-inputs.sh SOURCE_ROOT RESOLVED_MANIFEST JOBS" >&2
  exit 64
fi

readonly source_root=$1
readonly resolved_manifest=$2
readonly jobs=$3

if [[ ! -d "$source_root/.repo/projects" || ! -f "$resolved_manifest" ]]; then
  echo "error: AOSP source-input metadata is incomplete" >&2
  exit 64
fi
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: AOSP hydration concurrency must be positive" >&2
  exit 64
fi

python3 - "$resolved_manifest" <<'PY' |
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
default = root.find("default")
default_revision = default.get("revision") if default is not None else None
for project in root.findall("project"):
    path = project.get("path") or project.get("name")
    revision = project.get("revision")
    upstream = project.get("upstream") or default_revision
    if not path or not revision or not upstream:
        raise SystemExit("resolved manifest contains an invalid project")
    if any("\0" in value for value in (path, revision, upstream)):
        raise SystemExit("resolved manifest contains an invalid NUL byte")
    sys.stdout.buffer.write(
        path.encode() + b"\0" + revision.encode() + b"\0" +
        upstream.encode() + b"\0"
    )
PY
  xargs -0 -n 3 -P "$jobs" bash -c '
    set -euo pipefail
    readonly source_root=$1
    readonly path=$2
    readonly revision=$3
    readonly upstream=$4
    readonly git_dir="$source_root/.repo/projects/$path.git"
    if [[ ! -d "$git_dir" ]]; then
      echo "error: missing Repo project metadata for $path" >&2
      exit 65
    fi
    readonly remote=$(git --git-dir="$git_dir" remote | head -1)
    if [[ -z "$remote" ]]; then
      echo "error: missing Repo project remote for $path" >&2
      exit 65
    fi
    git --git-dir="$git_dir" fetch \
      --quiet --force --no-filter --no-tags --depth=1 "$remote" "$upstream"
    if git --git-dir="$git_dir" ls-tree -r \
        --format="%(objectmode) %(objectname)" "$revision" |
        awk "\$1 != \"160000\" { print \$2 }" |
        GIT_NO_LAZY_FETCH=1 git --git-dir="$git_dir" cat-file \
          --batch-check="%(objectname) %(objecttype)" |
        grep -q " missing$"; then
      echo "error: locked AOSP tree remains incomplete for $path" >&2
      exit 65
    fi
  ' _ "$source_root"

# Object stores the locked manifest no longer names.
#
# `repo` creates a store per project it has ever synced and never removes one,
# so a manifest that drops a project, or a sync that selected a different
# platform's host prebuilts, leaves its objects behind reachable from nothing.
# This host carried 5.3 GiB of Darwin toolchain objects that way: no checkout
# names them, no gitdir points at them, and the guest volume that reads this
# store through a symlink never asks for them.
#
# Membership in the locked manifest is the test, and an existing project
# gitdir is a second one. A store is removed only when both agree it is
# unreferenced, because a store still backing a checkout would take the
# checkout with it.
python3 - "$source_root" "$resolved_manifest" <<'PY'
import os
import shutil
import sys
import xml.etree.ElementTree as ET

source_root, resolved_manifest = sys.argv[1], sys.argv[2]
objects_root = os.path.join(source_root, ".repo", "project-objects")
projects_root = os.path.join(source_root, ".repo", "projects")
if not os.path.isdir(objects_root):
    raise SystemExit(0)

named = {
    project.get("name")
    for project in ET.parse(resolved_manifest).getroot().findall("project")
    if project.get("name")
}
if not named:
    raise SystemExit("resolved manifest names no project")

unreferenced = []
for directory, entries, _ in os.walk(objects_root):
    for entry in list(entries):
        if not entry.endswith(".git"):
            continue
        entries.remove(entry)
        store = os.path.join(directory, entry)
        name = os.path.relpath(store, objects_root)[: -len(".git")]
        if name in named:
            continue
        if os.path.exists(os.path.join(projects_root, name + ".git")):
            continue
        unreferenced.append((name, store))

collected = 0
for name, store in sorted(unreferenced):
    size = 0
    for path, _, files in os.walk(store):
        for file in files:
            try:
                size += os.lstat(os.path.join(path, file)).st_size
            except OSError:
                pass
    try:
        shutil.rmtree(store)
    except OSError as error:
        print(f"could not collect {name}: {error}", file=sys.stderr)
        continue
    collected += size
    print(f"collected unreferenced object store {name} ({size} bytes)", file=sys.stderr)
if unreferenced:
    print(f"collected {collected} bytes of unreferenced object stores", file=sys.stderr)
PY
