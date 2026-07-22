#!/usr/bin/env bash
# Run the compositor with the Khronos Vulkan validation layer attached.
# Useful for catching layout transition errors, sync hazards, queue
# family transfer mistakes, and other GPU-side bugs that don't show
# up without validation.
#
# Validation makes Vulkan calls slower (~2-5x for some ops) and emits
# a lot of output. The Khronos validation layer prints to STDOUT by
# default; this script merges its stdout into stderr so the caller's
# usual `2> nucleus.log` redirect captures everything in one stream
# (compositor's own logs + validation messages, time-interleaved).
#
# Usage:
#   ./scripts/run-vk-validation.sh 2> nucleus.log
#
# Repro pattern:
#   1. Run this script from the repository root; redirect 2>
#   2. Trigger the suspected bug (e.g. take 5 screenshots in succession)
#   3. Exit (Ctrl+Alt+Backspace inside the compositor)
#   4. grep -E 'VUID|SYNC-HAZARD|Validation Error' nucleus.log | head -50
#
# Install the distro Vulkan validation-layer package. This script discovers its
# standard manifest directory and enables validation through the typed session
# configuration; the layer is appended to the instance's pp_enabled_layer_names
# directly, not via VK_INSTANCE_LAYERS. That distinction matters
# because VK_INSTANCE_LAYERS is read by the Vulkan loader in *every*
# child process the compositor spawns (Chrome, kitty, anything Vulkan-
# using), causing them to also attach validation and emit unrelated
# VUIDs into our log. The typed configuration is delivered over private inherited
# descriptors and means nothing to the loader, so child inheritance is harmless.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

layer_dirs=()
IFS=: read -ra configured_layer_dirs <<< "${VK_LAYER_PATH:-}"
layer_dirs+=("${configured_layer_dirs[@]}")
layer_dirs+=(
    "${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/explicit_layer.d"
    "/usr/local/share/vulkan/explicit_layer.d"
    "/usr/share/vulkan/explicit_layer.d"
)
IFS=: read -ra data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for data_dir in "${data_dirs[@]}"; do
    layer_dirs+=("$data_dir/vulkan/explicit_layer.d")
done

validation_manifest=""
for layer_dir in "${layer_dirs[@]}"; do
    [[ -d "$layer_dir" ]] || continue
    for manifest in "$layer_dir"/*.json; do
        [[ -f "$manifest" ]] || continue
        if grep -Eq '"name"[[:space:]]*:[[:space:]]*"VK_LAYER_KHRONOS_validation"' "$manifest"; then
            validation_manifest="$manifest"
            break 2
        fi
    done
done

if [[ -z "$validation_manifest" ]]; then
    echo "error: VK_LAYER_KHRONOS_validation was not found; install vulkan-validationlayers" >&2
    exit 1
fi

# Ensure a manifest found in a standard/XDG directory remains visible even when
# the caller supplied a restrictive VK_LAYER_PATH.
validation_layer_dir="$(dirname "$validation_manifest")"
export VK_LAYER_PATH="$validation_layer_dir${VK_LAYER_PATH:+:$VK_LAYER_PATH}"

if [[ "${1:-}" == "--check" ]]; then
    exit 0
fi

workspace_root="$(cd "$repo_root/.." && pwd)"
exec "$workspace_root/tools/nucleus" run --vk-validation -- "$@"
