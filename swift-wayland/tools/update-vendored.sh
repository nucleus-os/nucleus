#!/usr/bin/env bash
# Refresh the vendored upstream wayland-protocols XML (stable/staging/unstable) from freedesktop,
# then regenerate the committed Wayland bindings. Vendored (not a submodule) so consumers clone
# this package and build offline. The curated kde/wlr extras + core wayland.xml under
# Protocols/protocols are maintained by hand (they aren't part of wayland-protocols) and left alone.
#
#   tools/update-vendored.sh <tag>      # e.g. 1.45
#
# Run from your dev shell (needs `swift` + `wayland-scanner` for the regen).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:?usage: update-vendored.sh <wayland-protocols tag, e.g. 1.45>}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 --branch "$REF" https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$TMP/wp"
COMMIT="$(git -C "$TMP/wp" rev-parse HEAD)"

DEST="$ROOT/Protocols/wayland-protocols"
for d in stable staging unstable; do
    rm -rf "$DEST/$d"
    cp -r "$TMP/wp/$d" "$DEST/$d"
done
echo "wayland-protocols pinned commit: $COMMIT ($REF)" > "$DEST/VENDORED_VERSION"

echo "Vendored wayland-protocols $REF ($COMMIT); regenerating bindings…"
( cd "$ROOT" && swift package generate-wayland --allow-writing-to-package-directory )
echo "Done. Review the diff, run 'swift test', then commit + tag."
