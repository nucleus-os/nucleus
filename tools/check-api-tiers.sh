#!/usr/bin/env bash
# Enforce the API tier boundary.
#
# SwiftPM does *not* enforce declared target dependencies: every built module
# lands in one search path, so once a package is depended on anywhere, all its
# products are importable whether or not the target declares them. A target's
# dependency list documents intent; it does not stop an import. This check does.
#
# Tiers (core/docs/appkit-api-plan.md):
#   product  — authors against NucleusUI/NucleusApp only
#   embedder — NucleusUIEmbedder; platform integrators
#   internal — NucleusLayers, NucleusRenderer, NucleusRenderModel, …
set -uo pipefail
cd "$(dirname "$0")/.."

# Product-tier source directories, and what they may not import.
PRODUCT_DIRS=(
  "shell/Sources/NucleusShellProduct"
)
FORBIDDEN='NucleusUIEmbedder|NucleusLayers|NucleusRenderer|NucleusRenderModel|NucleusAppHostBundle|NucleusAppHostProtocols|NucleusSkiaGraphiteBridge'

status=0
for dir in "${PRODUCT_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  hits=$(grep -rnE "^[[:space:]]*(@_spi\([A-Za-z]*\) )?(public |internal |package |fileprivate )?import ($FORBIDDEN)\b" "$dir" || true)
  if [ -n "$hits" ]; then
    echo "error: product-tier code may not import embedder or SDK-internal modules:"
    echo "$hits" | sed 's/^/  /'
    status=1
  fi
done

# NucleusUI is the product front door: it must carry no SPI declarations, or
# privilege leaks back in through the door this boundary replaced.
spi=$(grep -rn "@_spi([A-Za-z]*) \(public\|package\)" core/swift/Sources/NucleusUI/ || true)
if [ -n "$spi" ]; then
  echo "error: NucleusUI declares SPI; privilege belongs behind a module boundary:"
  echo "$spi" | sed 's/^/  /'
  status=1
fi

# Nothing should reach NucleusUI through an SPI import any more.
imports=$(grep -rn "@_spi([A-Za-z]*) import NucleusUI\b" --include=*.swift . || true)
if [ -n "$imports" ]; then
  echo "error: NucleusUI is imported with an SPI annotation:"
  echo "$imports" | sed 's/^/  /'
  status=1
fi

[ $status -eq 0 ] && echo "api tiers: ok"
exit $status
