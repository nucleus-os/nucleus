#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

host_toolchain() {
  local toolchain="$1"
  local work="$2"
  local executable product target
  for executable in \
    swift swiftc clang clang++ lldb lldb-argdumper lldb-dap lldb-server \
    repl_swift sourcekit-lsp swift-format docc wasmkit
  do
    [[ -x "$toolchain/bin/$executable" ]] \
      || fail "Linux toolchain executable is missing: $toolchain/bin/$executable"
  done
  for product in \
    lib/liblldb.so \
    lib/libIndexStore.so \
    lib/libSwiftSourceKitClientPlugin.so \
    lib/libSwiftSourceKitPlugin.so \
    lib/swift/linux/Foundation.swiftmodule \
    lib/swift/linux/FoundationEssentials.swiftmodule \
    lib/swift/linux/FoundationInternationalization.swiftmodule \
    lib/swift/linux/FoundationNetworking.swiftmodule \
    lib/swift/linux/FoundationXML.swiftmodule \
    lib/swift/linux/Dispatch.swiftmodule \
    lib/swift/linux/libFoundation.so \
    lib/swift/linux/libdispatch.so \
    lib/swift_static/linux/Foundation.swiftmodule \
    lib/swift_static/linux/Dispatch.swiftmodule \
    lib/swift_static/linux/Glibc.swiftmodule \
    lib/swift_static/linux/libFoundation.a \
    lib/swift_static/linux/libdispatch.a \
    lib/swift/embedded \
    lib/swift_static/embedded \
    share/docc/render
  do
    [[ -e "$toolchain/$product" ]] \
      || fail "Linux toolchain product is missing: $toolchain/$product"
  done
  local targets
  targets="$($toolchain/bin/clang --print-targets)"
  for target in aarch64 arm avr bpf mips ppc32 riscv32 systemz wasm32 x86; do
    grep -Eq "^[[:space:]]*$target[[:space:]]" <<<"$targets" \
      || fail "Linux Clang is missing LLVM target $target"
  done
  rm -rf "$work"
  mkdir -p "$work/home" "$work/tmp"
  printf '%s\n' \
    'import Foundation' \
    '@main struct Smoke {' \
    '  static func main() {' \
    '    precondition(URL(fileURLWithPath: "/tmp").path == "/tmp")' \
    '  }' \
    '}' >"$work/smoke.swift"
  HOME="$work/home" TMPDIR="$work/tmp" \
    "$toolchain/bin/swiftc" -parse-as-library "$work/smoke.swift" -o "$work/smoke"
  "$work/smoke"
  "$toolchain/bin/swift-format" --version >/dev/null
  "$toolchain/bin/docc" --help >/dev/null
  "$toolchain/bin/wasmkit" --version >/dev/null
  rm -rf "$work"
}

android_linkage() {
  local install_root="$1"
  shift
  local tools=/usr/bin
  local architecture library dynamic symbols
  for architecture in "$@"; do
    library="$install_root/install-$architecture/usr/lib/swift/android/libswiftCore.so"
    [[ -f "$library" ]] || fail "Android libswiftCore is missing: $library"
    dynamic="$($tools/llvm-readelf -d "$library")"
    grep -Fq 'Shared library: [libc++_shared.so]' <<<"$dynamic" \
      || fail "Android libswiftCore does not depend on libc++_shared.so: $library"
    if grep -Fq 'Shared library: [libstdc++' <<<"$dynamic"; then
      fail "Android libswiftCore depends on libstdc++: $library"
    fi
    symbols="$("$tools/llvm-nm" --dynamic --demangle "$library")"
    if grep -Fq 'std::__cxx11::' <<<"$symbols"; then
      fail "Android libswiftCore contains libstdc++ ABI symbols: $library"
    fi
  done
}

android_sdk() {
  local toolchain="$1"
  local sdk_root="$2"
  local bundle_name="$3"
  local architecture="$4"
  local api_level="$5"
  local work="$6"
  local fixture="$7"
  local triple="${architecture}-unknown-linux-android${api_level}"
  local expected_machine
  case "$architecture" in
    aarch64) expected_machine=AArch64 ;;
    x86_64) expected_machine='Advanced Micro Devices X86-64' ;;
    *) fail "unsupported Android SDK architecture: $architecture" ;;
  esac
  [[ -d "$sdk_root/$bundle_name" ]] \
    || fail "Android Swift SDK bundle is missing: $sdk_root/$bundle_name"
  rm -rf "$work"
  mkdir -p "$(dirname "$work")"
  cp -R "$fixture" "$work"
  local mode build binary
  for mode in dynamic static; do
    build="$work/.build-$mode"
    local arguments=(
      build --package-path "$work" --build-path "$build"
      --swift-sdks-path "$sdk_root" --swift-sdk "$triple"
    )
    if [[ "$mode" == static ]]; then arguments+=(--static-swift-stdlib); fi
    ANDROID_NDK_HOME=/opt/android-ndk-r30-beta2 \
      "$toolchain/bin/swift" "${arguments[@]}"
    binary="$(find "$build" -type f -name hello -perm -111 -print -quit)"
    [[ -n "$binary" ]] || fail "$mode Android consumer executable is missing"
    local machine
    machine="$(
      /usr/bin/llvm-readelf \
        -h "$binary" | grep -F 'Machine:'
    )"
    grep -Fq "$expected_machine" <<<"$machine" \
      || fail "$mode Android consumer has the wrong machine type: $binary"
    find "$build" -type f -name FoundationXMLHostPlugin -perm -111 -print -quit \
      | grep -q . || fail "FoundationXMLHostPlugin was not built"
  done
  rm -rf "$work"
}

case "${1:-}" in
  host)
    [[ $# -eq 3 ]] || fail "usage: validate-artifacts.sh host TOOLCHAIN WORK"
    host_toolchain "$2" "$3"
    ;;
  android-linkage)
    [[ $# -ge 3 ]] || fail "usage: validate-artifacts.sh android-linkage INSTALL_ROOT ARCH..."
    install_root="$2"
    shift 2
    android_linkage "$install_root" "$@"
    ;;
  android-sdk)
    [[ $# -eq 8 ]] || fail "usage: validate-artifacts.sh android-sdk TOOLCHAIN SDK_ROOT BUNDLE ARCH API WORK FIXTURE"
    android_sdk "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    ;;
  *)
    fail "expected validation mode: host, android-linkage, or android-sdk"
    ;;
esac
