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
