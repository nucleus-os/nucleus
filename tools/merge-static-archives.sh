#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: merge-static-archives.sh SOURCE_ROOT OUTPUT [EXCLUDED_BASENAME_PREFIX ...]" >&2
  exit 64
fi

source_root=$1
output=$2
shift 2

if [[ ! -d "$source_root" ]]; then
  echo "error: static archive source root does not exist: $source_root" >&2
  exit 66
fi

mkdir -p "$(dirname "$output")"
mri=$(mktemp "${output}.mri.XXXXXX")
trap 'rm -f "$mri"' EXIT

printf 'create %s\n' "$output" >"$mri"
archive_count=0
while IFS= read -r -d '' archive; do
  [[ "$archive" == "$output" ]] && continue
  basename=${archive##*/}
  excluded=false
  for prefix in "$@"; do
    if [[ "$basename" == "$prefix"* ]]; then
      excluded=true
      break
    fi
  done
  "$excluded" && continue
  printf 'addlib %s\n' "$archive" >>"$mri"
  archive_count=$((archive_count + 1))
done < <(find "$source_root" -type f -name '*.a' -print0 | sort -z)

if [[ $archive_count -eq 0 ]]; then
  echo "error: no static archives found under $source_root" >&2
  exit 66
fi

printf 'save\nend\n' >>"$mri"
rm -f "$output"
llvm-ar -M <"$mri"
llvm-ranlib "$output"
