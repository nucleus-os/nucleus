#!/usr/bin/env bash
# Workspace-owned Collider launcher. The installed `collider` shim delegates
# here so launcher behavior always comes from the active checkout.
set -euo pipefail

root="${NUCLEUS_WORKSPACE_ROOT:-}"
if [[ -z "$root" || ! -f "$root/collider/Package.swift" ]]; then
  dir="$PWD"
  root=""
  while [[ "$dir" != / ]]; do
    if [[ -f "$dir/collider-setup.sh" && -f "$dir/collider/Package.swift" ]]; then
      root="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
fi
if [[ -z "$root" ]]; then
  echo "collider: not inside a Nucleus workspace (no clone at or above $PWD)" >&2
  exit 1
fi

export NUCLEUS_WORKSPACE_ROOT="$root"
host_env="$root/tools/host-env.sh"
if ! ( source "$host_env" ) >/dev/null 2>&1; then
  echo "collider: the native host compiler is unavailable; run $root/collider-setup.sh" >&2
  exit 1
fi
source "$host_env"

pkg="$root/collider"
bin="$pkg/.build/release/collider"
fingerprint_file="$pkg/.build/collider-release-source.sha256"
"$root/tools/configure-swiftpm-mirrors.sh"

hash_standard_input() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

append_repository_state() {
  local repository="$1"
  local label="$2"
  shift 2
  local path
  printf 'repository\0%s\0' "$label"
  git -C "$repository" rev-parse HEAD
  git -C "$repository" diff \
    --binary --no-ext-diff --ignore-submodules=all HEAD -- "$@"
  while IFS= read -r -d '' path; do
    printf 'untracked\0%s\0' "$path"
    git -C "$repository" hash-object --no-filters -- "$path"
  done < <(git -C "$repository" ls-files --others --exclude-standard -z -- "$@")
}

collider_source_fingerprint() {
  local source_repository
  local source_repositories=(
    third-party/container
    third-party/containerization
    third-party/swift-argument-parser
    third-party/swift-crypto
    third-party/swift-log
    third-party/swift-subprocess
    third-party/swift-system
  )
  local root_paths=(
    collider/Package.swift
    collider/Package.resolved
    collider/Sources
    collider/engine/Package.swift
    collider/engine/Package.resolved
    collider/engine/Sources
    tools/collider-launcher.sh
    tools/configure-swiftpm-mirrors.sh
    tools/host-env.sh
    tools/host-platform-env.sh
  )
  if [[ "$(uname -s)" != Darwin ]]; then
    # Linux Collider links the supported root-package protocol products.
    root_paths=(.)
  fi
  {
    swiftc --version 2>&1
    append_repository_state "$root" . "${root_paths[@]}"
    # These are the root-owned source repositories in Collider's SwiftPM
    # dependency closure. Remote transitive packages remain SwiftPM-owned.
    for source_repository in "${source_repositories[@]}"; do
      append_repository_state "$root/$source_repository" "$source_repository" .
    done
  } | hash_standard_input
}

# Git supplies the committed, modified, staged, and untracked identity of
# Collider's compilation closure. SwiftPM remains the sole builder; the launcher
# only avoids asking it to re-plan a source/toolchain state it has already built.
fingerprint="$(collider_source_fingerprint)"
recorded_fingerprint=""
if [[ -r "$fingerprint_file" ]]; then
  recorded_fingerprint="$(<"$fingerprint_file")"
fi
if [[ ! -x "$bin" || "$fingerprint" != "$recorded_fingerprint" ]]; then
  swift build --package-path "$pkg" -c release --product collider >&2
  mkdir -p "$(dirname "$fingerprint_file")"
  fingerprint="$(collider_source_fingerprint)"
  temporary_fingerprint="$fingerprint_file.$$"
  printf '%s\n' "$fingerprint" >"$temporary_fingerprint"
  mv -f "$temporary_fingerprint" "$fingerprint_file"
fi

if [[ "${COLLIDER_REFRESH_ONLY:-0}" == 1 ]]; then
  exit 0
fi

export COLLIDER_ENTRYPOINT=workspace-launcher
exec "$bin" "$@"
