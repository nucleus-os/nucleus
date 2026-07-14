#!/usr/bin/env bash
# Refresh the vendored Vulkan headers + registry vk.xml from KhronosGroup/Vulkan-Headers, then
# regenerate the committed Vulkan.swift bindings. Vendored (not a submodule) so consumers
# clone this package and build offline, without fetching Khronos at resolve time. Only the headers
# already present are refreshed — a header appearing/disappearing upstream is a real change to
# review, not a silent one.
#
#   tools/update-vendored.sh <tag>      # e.g. v1.4.350
#
# Run from your dev shell (needs `swift` for the regen).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:?usage: update-vendored.sh <Vulkan-Headers tag, e.g. v1.4.350>}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 --branch "$REF" https://github.com/KhronosGroup/Vulkan-Headers.git "$TMP/vh"
COMMIT="$(git -C "$TMP/vh" rev-parse HEAD)"

# Refresh each header already vendored (preserves the curated set) + the registry vk.xml.
for h in "$ROOT"/Sources/VulkanC/vulkan/*.h; do
    cp "$TMP/vh/include/vulkan/$(basename "$h")" "$h"
done
cp "$TMP/vh/registry/vk.xml" "$ROOT/third-party/vk.xml"
echo "KhronosGroup/Vulkan-Headers $REF ($COMMIT)" > "$ROOT/third-party/VULKAN_HEADERS_VERSION"

echo "Vendored Vulkan-Headers $REF ($COMMIT); regenerating bindings…"
( cd "$ROOT" && swift package generate-vulkan --allow-writing-to-package-directory )
echo "Done. Review the diff, run 'swift test', then commit + tag."
