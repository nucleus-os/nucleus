#!/bin/sh
# Sync third-party deps and apply local patches.
# Run from the nucleus repo root.
set -e
cd "$(dirname "$0")/.."
CORE="$PWD"
WORKSPACE="$(cd .. && pwd)"

PATCHES="third-party/patches"
SKIA="third-party/skia"

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

echo "Done."
