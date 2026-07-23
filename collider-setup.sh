#!/usr/bin/env bash
# Nucleus first-run setup and repair. Run this once on a fresh clone:
#
#   ./collider-setup.sh
#
# It provisions the Swift toolchain if missing, builds the optimized `collider`
# binary, installs the `collider` launcher on your PATH, and provisions the
# workspace. Re-run it any time to verify and repair the installation. This
# script performs setup only; use the installed `collider` command for
# everything else.
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

# True when a Nucleus toolchain resolves; host-env exits nonzero otherwise.
toolchain_present() { ( source "$host_env" ) >/dev/null 2>&1; }

# 1. Provision the Nucleus toolchain if absent. The first generation is built by
#    a Swift 6.4 bootstrap compiler on PATH; every later build uses host-env's
#    active toolchain.
if ! toolchain_present; then
  if ! command -v swift >/dev/null 2>&1; then
    echo "error: Swift 6.4 must be on PATH to create the first Nucleus toolchain generation." >&2
    exit 127
  fi
  echo "collider-setup: building collider with the bootstrap compiler..." >&2
  swift build --package-path "$pkg" -c release --product collider >&2
  "$bin" toolchain rebuild
fi

# 2. Build the optimized collider binary under the Nucleus toolchain.
source "$host_env"
echo "collider-setup: building collider (release)..." >&2
swift build --package-path "$pkg" -c release --product collider >&2

# 3. Install / repair the `collider` launcher on PATH.
install_launcher() {
  local bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
  local target="$bin_dir/collider"
  mkdir -p "$bin_dir"

  local desired
  desired="$(cat <<'LAUNCHER'
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
  echo "collider: the Nucleus toolchain is not installed; run $root/collider-setup.sh" >&2
  exit 1
fi
source "$host_env"

pkg="$root/collider"
bin="$pkg/.build/release/collider"

# Build inputs: the collider package and every *ColliderRecipe target. The
# binary's mtime is the fingerprint; rebuild only when an input is newer.
input_roots=("$pkg/Package.swift" "$pkg/Sources" "$pkg/engine")
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
  newer="$(find -L "${existing[@]}" -type f -newer "$bin" \
    -not -path '*/.build/*' -print -quit 2>/dev/null)"
  [[ -z "$newer" ]]
}

if collider_is_current; then
  exec "$bin" "$@"
fi
swift build --package-path "$pkg" -c release --product collider >&2
exec "$bin" "$@"
LAUNCHER
)"

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

# 4. Provision native SDKs and workspace state.
echo "collider-setup: provisioning workspace (collider bootstrap)..." >&2
"$bin" bootstrap

echo "collider-setup: done. Run 'collider' from any directory inside the clone." >&2
