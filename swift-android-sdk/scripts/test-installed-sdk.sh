#!/usr/bin/env bash
# Verify that the installed artifactbundle can build Android consumers.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/android-sdk-env.sh"

source_id="${NUCLEUS_SWIFT_SOURCE_ID:-release-6.4.x}"
toolchain_root="${NUCLEUS_SWIFT_TOOLCHAIN:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/${source_id}/usr}"
ndk_home="$(nucleus_android_ndk_home)"
api_level="${NUCLEUS_ANDROID_API_LEVEL:-36}"
arch="${NUCLEUS_SWIFT_ANDROID_TEST_ARCH:-aarch64}"
target_triple="${arch}-unknown-linux-android${api_level}"
case "$arch" in
  aarch64) readelf_machine='AArch64' ;;
  x86_64) readelf_machine='Advanced Micro Devices X86-64' ;;
  *) echo "unsupported test arch: $arch" >&2; exit 2 ;;
esac
bundle_name="${NUCLEUS_SWIFT_ANDROID_BUNDLE_NAME:-swift-${source_id}_android.artifactbundle}"
swift_bin="$toolchain_root/bin/swift"
readelf_bin=""
for candidate in "$ndk_home"/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
  if [[ -x "$candidate" ]]; then
    readelf_bin="$candidate"
    break
  fi
done
host_machine='Advanced Micro Devices X86-64'
sdk_search_root="${NUCLEUS_SWIFT_SDKS_PATH:-$HOME/.swiftpm/swift-sdks}"
installed_bundle="$sdk_search_root/$bundle_name"

if [[ ! -x "$swift_bin" ]]; then
  echo "swift not found at $swift_bin" >&2
  exit 1
fi
if [[ ! -d "$installed_bundle" ]]; then
  echo "Android Swift SDK is not installed at $installed_bundle" >&2
  echo "run tools/nucleus toolchain rebuild first" >&2
  exit 1
fi
if [[ ! -d "$ndk_home" ]]; then
  echo "Android NDK not found at $ndk_home" >&2
  exit 1
fi
if [[ -z "$readelf_bin" ]]; then
  echo "llvm-readelf not found under $ndk_home/toolchains/llvm/prebuilt" >&2
  exit 1
fi

export PATH="$toolchain_root/bin:$PATH"
export ANDROID_NDK_HOME="$ndk_home"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/nucleus-swift-android-consumer.XXXXXX")"
cleanup() {
  if [[ "${NUCLEUS_SWIFT_ANDROID_TEST_KEEP_TMP:-0}" != 1 ]]; then
    rm -rf "$tmp"
  else
    echo "kept temp package: $tmp" >&2
  fi
}
trap cleanup EXIT

echo "==> creating consumer package at $tmp" >&2
(
  cd "$tmp"
  mkdir -p Sources/hello Plugins/FoundationXMLHostPlugin
  cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AndroidSDKConsumer",
    products: [.executable(name: "hello", targets: ["hello"])],
    targets: [
        .executableTarget(
            name: "hello",
            swiftSettings: [.interoperabilityMode(.Cxx)],
            plugins: ["FoundationXMLHostPlugin"]),
        .plugin(name: "FoundationXMLHostPlugin", capability: .buildTool()),
    ]
)
SWIFT
  cat > Sources/hello/hello.swift <<'SWIFT'
import Foundation
import FoundationNetworking
import FoundationXML
import CxxStdlib

@main
struct Hello {
    static func main() {
        let url = URL(string: "https://example.com")!
        let parser = XMLParser(data: Data("<nucleus/>".utf8))
        precondition(parser.parse())
        let cxxString = std.string("nucleus")
        precondition(cxxString.size() == 7)
        print(url.host ?? "missing-host")
    }
}
SWIFT
  cat > Plugins/FoundationXMLHostPlugin/plugin.swift <<'SWIFT'
import Foundation
import FoundationXML
import PackagePlugin

@main
struct FoundationXMLHostPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let parser = XMLParser(data: Data("<host-tool/>".utf8))
        precondition(parser.parse())
        return []
    }
}
SWIFT

  "$swift_bin" build --build-path .build-dynamic --swift-sdks-path "$sdk_search_root" --swift-sdk "$target_triple"
  "$swift_bin" build --build-path .build-static --swift-sdks-path "$sdk_search_root" --swift-sdk "$target_triple" --static-swift-stdlib
)

for mode in dynamic static; do
  binary="$(find "$tmp/.build-$mode" -type f -name hello -perm -111 | head -n1)"
  if [[ -z "$binary" ]]; then
    echo "$mode hello executable not found under $tmp/.build-$mode" >&2
    exit 1
  fi

  "$readelf_bin" -h "$binary" | grep -q "Machine:[[:space:]]*$readelf_machine" || {
    echo "$mode executable is not $readelf_machine: $binary" >&2
    "$readelf_bin" -h "$binary" >&2
    exit 1
  }

  plugin="$(find "$tmp/.build-$mode" -type f -name FoundationXMLHostPlugin -perm -111 | head -n1)"
  if [[ -z "$plugin" ]]; then
    echo "$mode FoundationXML host plugin not found" >&2
    exit 1
  fi
  "$readelf_bin" -h "$plugin" | grep -q "Machine:[[:space:]]*$host_machine" || {
    echo "$mode host plugin is not $host_machine: $plugin" >&2
    "$readelf_bin" -h "$plugin" >&2
    exit 1
  }
done

echo "==> dynamic and static consumer builds passed: $target_triple"
