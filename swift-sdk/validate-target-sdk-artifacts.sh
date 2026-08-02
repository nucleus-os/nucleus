#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <linux-sdk-root> <linux-arm64> <linux-amd64> <android-arm64> <android-amd64>" >&2
    exit 64
fi

linux_sdk_root=$1
linux_arm64=$2
linux_amd64=$3
android_arm64=$4
android_amd64=$5
llvm_objdump=$(xcrun --find llvm-objdump)

require_file_description() {
    path=$1
    pattern=$2
    description=$(/usr/bin/file "$path")
    case "$description" in
        *"$pattern"*) ;;
        *)
            echo "unexpected artifact: $description" >&2
            exit 1
            ;;
    esac
}

require_interpreter() {
    path=$1
    pattern=$2
    if ! /usr/bin/file "$path" | grep -Fq "$pattern"; then
        echo "missing expected interpreter $pattern in $path" >&2
        exit 1
    fi
}

reject_libstdcxx() {
    path=$1
    if "$llvm_objdump" -p "$path" 2>/dev/null \
        | grep -Eq 'NEEDED[[:space:]]+libstdc\+\+'; then
        echo "forbidden libstdc++ dependency in $path" >&2
        exit 1
    fi
    if "$llvm_objdump" -T "$path" 2>/dev/null \
        | grep -q 'GLIBCXX_'; then
        echo "forbidden GLIBCXX symbol requirement in $path" >&2
        exit 1
    fi
}

require_libcxx() {
    path=$1
    if ! "$llvm_objdump" -p "$path" 2>/dev/null \
        | grep -Eq 'NEEDED[[:space:]]+libc\+\+'; then
        echo "missing libc++ dependency in $path" >&2
        exit 1
    fi
}

validate_linux_sdk_runtime() {
    triple=$1
    description_pattern=$2
    target_root="$linux_sdk_root/swift-linux/$triple/ubuntu-noble.sdk"
    if [ ! -d "$target_root" ]; then
        echo "missing Linux SDK target root: $target_root" >&2
        exit 1
    fi
    if find "$target_root" \
        \( -name 'libstdc++*' -o -name 'libstdcxx*' \) -print -quit \
        | grep -q .; then
        echo "Linux SDK exposes a forbidden libstdc++ artifact" >&2
        exit 1
    fi
    while IFS= read -r path; do
        description=$(/usr/bin/file "$path")
        case "$description" in
            *ELF*) reject_libstdcxx "$path" ;;
        esac
    done <<EOF
$(find "$target_root" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -111 \) -print)
EOF
    libcxx_soname=$(find "$target_root" -type l -name 'libc++.so.1' -print -quit)
    if [ -z "$libcxx_soname" ] || [ ! -f "$libcxx_soname" ]; then
        echo "Linux SDK does not ship libc++.so.1" >&2
        exit 1
    fi
    require_file_description "$libcxx_soname" "$description_pattern"
    reject_libstdcxx "$libcxx_soname"
    testing_module="$target_root/usr/lib/swift/linux/Testing.swiftmodule/$triple.swiftinterface"
    testing_library="$target_root/usr/lib/swift/linux/libTesting.so"
    if [ ! -f "$testing_module" ]; then
        echo "Linux SDK does not ship the Swift Testing module for $triple" >&2
        exit 1
    fi
    if [ ! -f "$testing_library" ]; then
        echo "Linux SDK does not ship libTesting.so for $triple" >&2
        exit 1
    fi
    require_file_description "$testing_library" "$description_pattern"
    reject_libstdcxx "$testing_library"
}

require_android_page_alignment() {
    path=$1
    "$llvm_objdump" -p "$path" | awk '
        /^[[:space:]]+LOAD / {
            found = 1
            if ($NF != "2**14") exit 1
        }
        END { if (!found) exit 1 }
    '
}

require_file_description "$linux_arm64" "ELF 64-bit LSB pie executable, ARM aarch64"
require_interpreter "$linux_arm64" "/lib/ld-linux-aarch64.so.1"
reject_libstdcxx "$linux_arm64"
require_libcxx "$linux_arm64"

require_file_description "$linux_amd64" "ELF 64-bit LSB pie executable, x86-64"
require_interpreter "$linux_amd64" "/lib64/ld-linux-x86-64.so.2"
reject_libstdcxx "$linux_amd64"
require_libcxx "$linux_amd64"
validate_linux_sdk_runtime \
    aarch64-unknown-linux-gnu \
    "ELF 64-bit LSB shared object, ARM aarch64"
validate_linux_sdk_runtime \
    x86_64-unknown-linux-gnu \
    "ELF 64-bit LSB shared object, x86-64"

require_file_description "$android_arm64" "ELF 64-bit LSB pie executable, ARM aarch64"
require_interpreter "$android_arm64" "/system/bin/linker64"
reject_libstdcxx "$android_arm64"
require_libcxx "$android_arm64"
require_android_page_alignment "$android_arm64"

require_file_description "$android_amd64" "ELF 64-bit LSB pie executable, x86-64"
require_interpreter "$android_amd64" "/system/bin/linker64"
reject_libstdcxx "$android_amd64"
require_libcxx "$android_amd64"
require_android_page_alignment "$android_amd64"
