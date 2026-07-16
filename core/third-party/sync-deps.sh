#!/bin/sh
# Sync third-party deps and apply local patches.
# Run from the nucleus repo root.
#
# Dawn is managed by Skia's git-sync-deps (not a git submodule), so its
# patches must be re-applied every time deps are synced. The zig-* bindings
# are regular submodules with patches committed directly.
set -e
cd "$(dirname "$0")/.."
CORE="$PWD"
WORKSPACE="$(cd .. && pwd)"

PATCHES="third-party/patches"
SKIA="third-party/skia"
DAWN="third-party/skia/third_party/externals/dawn"

echo "Initializing submodules..."
git -C "$WORKSPACE" submodule update --init --recursive core/third-party

echo "Syncing Skia third-party deps..."
python3 third-party/skia/tools/git-sync-deps

echo "Applying Skia patches..."
for patch in "$PATCHES"/skia-*.patch; do
    [ -f "$patch" ] || continue
    name=$(basename "$patch")
    echo "  $name"
    git -C "$SKIA" apply --check "$CORE/$patch" 2>/dev/null && \
        git -C "$SKIA" apply "$CORE/$patch" || \
        echo "  (already applied or conflicts — skipping)"
done

echo "Applying Dawn patches..."
for patch in "$PATCHES"/dawn-*.patch; do
    [ -f "$patch" ] || continue
    name=$(basename "$patch")
    echo "  $name"
    git -C "$DAWN" apply --check "$PWD/$patch" 2>/dev/null && \
        git -C "$DAWN" apply "$CORE/$patch" || \
        echo "  (already applied or conflicts — skipping)"
done

echo "Done."
