#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/../.." && pwd)"
source "$workspace_root/cef/scripts/cef-env.sh"
source "$script_dir/build-support.sh"

[[ "${NUCLEUS_CHROMIUM_ORCHESTRATED:-0}" == 1 ]] || {
  echo "doctor.sh is an internal stage; use tools/nucleus chromium doctor" >&2
  exit 2
}

mode="${1:-build}"
if [[ $# -gt 1 || ! "$mode" =~ ^(bootstrap|build)$ ]]; then
  echo "internal usage: doctor.sh [bootstrap|build]" >&2
  exit 2
fi
nucleus_chromium_preflight "$mode"
