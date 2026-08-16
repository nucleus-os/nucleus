#!/usr/bin/env bash
set -euo pipefail

products=${NUCLEUS_SWIFTPM_OVERLAY_PRODUCTS:?}
output=${NUCLEUS_SWIFTPM_OVERLAY_OUTPUT:?}
swiftpm_revision=${NUCLEUS_SWIFTPM_REVISION:?}
swiftbuild_revision=${NUCLEUS_SWIFTBUILD_REVISION:?}
swiftpm_source=${NUCLEUS_SWIFTPM_SOURCE:?}
swiftbuild_source=${NUCLEUS_SWIFTBUILD_SOURCE:?}
compiler_digest=${NUCLEUS_SWIFT_COMPILER_ARCHIVE_SHA256:?}
source_date_epoch=${SOURCE_DATE_EPOCH:?}

test "$(git -C "$swiftpm_source" rev-parse HEAD)" = "$swiftpm_revision"
test "$(git -C "$swiftbuild_source" rev-parse HEAD)" = "$swiftbuild_revision"
test -z "$(git -C "$swiftpm_source" status --porcelain)"
test -z "$(git -C "$swiftbuild_source" status --porcelain)"

executable="$products/swift-package-manager"
test -x "$executable"
find "$output" -mindepth 1 -delete
install -d "$output/usr/bin" "$output/usr/share/pm" \
  "$output/usr/share/nucleus"
install -m 0755 "$executable" "$output/usr/bin/swift-package-manager"
ln -s swift-package-manager "$output/usr/bin/swift-package"
ln -s swift-package-manager "$output/usr/bin/swift-build"
find "$products" -mindepth 1 -maxdepth 1 -type d \
  \( -name '*.bundle' -o -name '*.resources' \) \
  -exec cp -R {} "$output/usr/share/pm/" \;

universal_platform_resources=$(find "$output/usr/share/pm" \
  -mindepth 1 -maxdepth 1 -type d \
  \( -name 'SwiftBuild_SWBUniversalPlatform.bundle' \
     -o -name 'SwiftBuild_SWBUniversalPlatform.resources' \) \
  -print -quit)
test -n "$universal_platform_resources"
grep --fixed-strings 'SDKROOT = "$(HOST_PLATFORM)";' \
  "$universal_platform_resources/ProductTypes.xcspec"
printf '%s\n' \
  "swift-package-manager=$swiftpm_revision" \
  "swift-build=$swiftbuild_revision" \
  "swift-compiler-archive-sha256=$compiler_digest" \
  "overlay-mtime-epoch=$source_date_epoch" \
  > "$output/usr/share/nucleus/swiftpm-overlay-provenance.txt"

readelf --file-header "$output/usr/bin/swift-package-manager" \
  | grep --fixed-strings AArch64
test "$(readlink "$output/usr/bin/swift-package")" = swift-package-manager
test "$(readlink "$output/usr/bin/swift-build")" = swift-package-manager
LD_LIBRARY_PATH=/opt/swift/usr/lib/swift/linux:/opt/swift-compat/arm64 \
  SWIFTPM_EXEC_NAME=swift-build \
  "$output/usr/bin/swift-package-manager" --version
