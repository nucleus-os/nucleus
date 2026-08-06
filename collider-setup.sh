#!/usr/bin/env bash
# Nucleus first-run setup and repair. Run this once on a fresh clone:
#
#   ./collider-setup.sh
#
# It selects Xcode on macOS or provisions the generated host toolchain on Linux,
# builds the optimized `collider` binary, and installs the `collider` launcher
# on your PATH. Re-run it any time to repair the tool installation. Workspace
# readiness and build artifacts belong to Collider itself.
set -euo pipefail

case "${1:-}" in
  "" | --repair | --force) ;;
  *)
    echo "collider-setup.sh performs first-run setup and repair only." >&2
    echo "After setup, use the installed 'collider' command (e.g. 'collider build')." >&2
    exit 2
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NUCLEUS_WORKSPACE_ROOT="$root"

host_env="$root/tools/host-env.sh"
pkg="$root/collider"
bin="$pkg/.build/release/collider"

source "$root/tools/host-platform-env.sh"

# Collider builds a complete monorepo checkout. Initialize only absent
# submodules before compiling Collider itself. Existing checkouts are user
# source state and must never be reset to the index by setup/repair.
initialize_missing_submodules() {
  local line submodule_path
  while IFS= read -r line; do
    [[ "${line:0:1}" == "-" ]] || continue
    line="${line:1}"
    submodule_path="${line#* }"
    submodule_path="${submodule_path%% *}"
    if git -C "$root/$submodule_path" rev-parse --is-inside-work-tree \
        >/dev/null 2>&1; then
      continue
    fi
    echo "collider-setup: initializing submodule $submodule_path..." >&2
    git -C "$root" submodule update --init --recursive -- "$submodule_path"
  done < <(git -C "$root" submodule status --recursive)
}
initialize_missing_submodules

# True when the native host compiler resolves. macOS uses the selected Xcode;
# Linux host execution uses the active generated toolchain for that host.
toolchain_present() { ( source "$host_env" ) >/dev/null 2>&1; }

# 1. Provision the generated Linux toolchain when setup itself runs on Linux.
#    macOS builds Collider and native products with the selected Xcode toolchain;
#    `collider swift-sdk rebuild` separately creates Linux/Android artifacts in
#    the pinned native Linux/arm64 builder image.
if ! toolchain_present; then
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "error: full Xcode 27 with Swift 6.4 must be selected" >&2
    exit 127
  fi
  if ! command -v swift >/dev/null 2>&1; then
    echo "error: Swift 6.4 must be on PATH to create the first Nucleus toolchain generation." >&2
    exit 127
  fi
  echo "collider-setup: building collider with the bootstrap compiler..." >&2
  "$root/tools/configure-swiftpm-mirrors.sh"
  swift build --package-path "$pkg" -c release >&2
  "$bin" swift-sdk rebuild
fi

# 2. Build the optimized collider binary with the native host compiler.
source "$host_env"
"$root/tools/configure-swiftpm-mirrors.sh"
echo "collider-setup: building collider (release)..." >&2
swift build --package-path "$pkg" -c release >&2

# 3. Install / repair the `collider` launcher on PATH.
install_launcher() {
  local bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
  local target="$bin_dir/collider"
  mkdir -p "$bin_dir"

  local desired
  IFS= read -r -d '' desired <<'LAUNCHER' || true
#!/usr/bin/env bash
# collider launcher — installed by collider-setup.sh. Discovers the Nucleus
# clone from the current directory, keeps the optimized binary current, and runs
# it. Works only inside a clone; for first-run setup use ./collider-setup.sh.
set -euo pipefail

dir="$PWD"
root=""
while [[ "$dir" != / ]]; do
  if [[ -f "$dir/collider-setup.sh" && -f "$dir/collider/Package.swift" ]]; then
    root="$dir"
    break
  fi
  dir="$(dirname "$dir")"
done
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
"$root/tools/configure-swiftpm-mirrors.sh"

# Build inputs: the collider package and every *ColliderRecipe target. The
# binary's mtime is the fingerprint; rebuild only when an input is newer.
input_roots=(
  "$pkg/Package.swift"
  "$pkg/Sources"
  "$pkg/engine"
  "$root/tools/configure-swiftpm-mirrors.sh"
)
while IFS= read -r recipe; do
  input_roots+=("$recipe")
done < <(find "$root" -maxdepth 5 -type d -name '*ColliderRecipe' \
  -not -path '*/.build/*' 2>/dev/null)
existing=()
for path in "${input_roots[@]}"; do
  [[ -e "$path" ]] && existing+=("$path")
done

collider_is_current() {
  [[ -x "$bin" ]] || return 1
  local newer
  newer="$(find -L "${existing[@]}" -type f \
    -newer "$bin" \
    -not -path '*/.build/*' -print -quit 2>/dev/null)"
  [[ -z "$newer" ]]
}

if collider_is_current; then
  exec "$bin" "$@"
fi
swift build --package-path "$pkg" -c release >&2
exec "$bin" "$@"
LAUNCHER
  desired="${desired%$'\n'}"

  if [[ -f "$target" ]] && [[ "$(cat "$target")" == "$desired" ]] \
     && [[ -x "$target" ]]; then
    echo "collider-setup: launcher already current at $target" >&2
  else
    local tmp="$bin_dir/.collider.$$"
    printf '%s\n' "$desired" >"$tmp"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$target"
    echo "collider-setup: installed launcher at $target" >&2
  fi

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      echo "collider-setup: add $bin_dir to your PATH to run 'collider' from anywhere:" >&2
      echo "    export PATH=\"$bin_dir:\$PATH\"" >&2
      ;;
  esac
}
install_launcher

echo "collider-setup: done. Run 'collider doctor', then 'collider build'." >&2
