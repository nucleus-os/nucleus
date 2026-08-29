#!/usr/bin/env bash
set -euo pipefail

products=${NUCLEUS_SWIFTPM_OVERLAY_PRODUCTS:?}
output=${NUCLEUS_SWIFTPM_OVERLAY_OUTPUT:?}
swiftpm_revision=${NUCLEUS_SWIFTPM_REVISION:?}
swiftbuild_revision=${NUCLEUS_SWIFTBUILD_REVISION:?}
compiler_digest=${NUCLEUS_SWIFT_COMPILER_ARCHIVE_SHA256:?}
source_date_epoch=${SOURCE_DATE_EPOCH:?}

# Each source is checked against its manifest revision, and for cleanliness, on
# the host before this runs. A gitlink's `.git` is a file naming a directory in
# the superproject wherever the checkout was made by cloning with submodules,
# and only the submodule subtree crosses into here, so git inside this container
# can only answer for a checkout whose repository happens to sit in place. The
# whole repository is present on the host and answers for either shape.

executable="$products/swift-package-manager"
test -x "$executable"
find "$output" -mindepth 1 -delete
install -d "$output/usr/bin" "$output/usr/share/pm" \
  "$output/usr/share/nucleus"
install -m 0755 "$executable" "$output/usr/bin/swift-package-manager"
ln -s swift-package-manager "$output/usr/bin/swift-package"
ln -s swift-package-manager "$output/usr/bin/swift-build"
ln -s swift-package-manager "$output/usr/bin/swift-nucleus-driver"
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
test "$(readlink "$output/usr/bin/swift-nucleus-driver")" = swift-package-manager
LD_LIBRARY_PATH=/opt/swift/usr/lib/swift/linux:/opt/swift-compat/arm64 \
  SWIFTPM_EXEC_NAME=swift-build \
  "$output/usr/bin/swift-package-manager" --version
