#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: stage-runtime-elf.sh PRODUCTS_DIRECTORY STAGING_PREFIX" >&2
  exit 64
fi

products=$1
prefix=$2

bin_executables=(
  NucleusCompositor
  NucleusShell
  nucleus
)

libexec_executables=(
  NucleusConfigService
  NucleusControlService
  NucleusShellPamHelper
  NucleusSessionSupervisor
)

fail() {
  echo "runtime ELF staging failed: $*" >&2
  exit 1
}

copy_artifact() {
  local name=$1 destination=$2
  [[ -f "$products/$name" ]] ||
    fail "missing build artifact $products/$name"
  install -m 0755 "$products/$name" "$destination/$name"
}

mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/libexec" "$prefix/share/nucleus"

for artifact in "${bin_executables[@]}"; do
  copy_artifact "$artifact" "$prefix/bin"
done
for artifact in "${libexec_executables[@]}"; do
  copy_artifact "$artifact" "$prefix/libexec"
done

# Resolve the non-system dynamic closure while the copied artifacts still carry
# their build-time runpaths. Host libraries under /lib and /usr/lib remain host
# dependencies. Toolchain-owned Swift, Foundation, Dispatch, libc++, and unwind
# libraries are copied into the runtime so the installed tree has no dependency
# on a developer toolchain path.
queue=()
for artifact in "$prefix"/bin/* "$prefix"/lib/* "$prefix"/libexec/*; do
  [[ -f "$artifact" ]] && queue+=("$artifact")
done

index=0
while [[ $index -lt ${#queue[@]} ]]; do
  artifact=${queue[$index]}
  index=$((index + 1))

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*)
        continue
        ;;
    esac

    name=${dependency##*/}
    destination="$prefix/lib/$name"
    if [[ -e "$destination" ]]; then
      continue
    fi
    [[ -f "$dependency" ]] ||
      fail "$artifact resolves a dependency to a missing file: $dependency"
    install -m 0755 "$dependency" "$destination"
    queue+=("$destination")
  done < <(
    ldd "$artifact" |
      awk '
        /=> \// { print $3; next }
        /^[[:space:]]*\// { sub(/^[[:space:]]*/, "", $1); print $1 }
      '
  )
done

for artifact in "$prefix"/lib/*; do
  patchelf --set-rpath '$ORIGIN' "$artifact"
done
for artifact in "$prefix"/bin/NucleusCompositor \
                "$prefix"/bin/NucleusShell \
                "$prefix"/bin/nucleus \
                "$prefix"/libexec/*; do
  patchelf --set-rpath '$ORIGIN/../lib' "$artifact"
done

# Strip only debug sections. Swift reflection metadata, dynamic symbols, and
# executable entry points remain intact and are validated after staging.
for artifact in "$prefix"/bin/NucleusCompositor \
                "$prefix"/bin/NucleusShell \
                "$prefix"/bin/nucleus \
                "$prefix"/lib/* \
                "$prefix"/libexec/*; do
  strip --strip-debug "$artifact"
done

echo "runtime ELF staging passed: $prefix"
