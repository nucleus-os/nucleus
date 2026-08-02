#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <linux-sdk-root> <linux-amd64> <android-arm64> <android-amd64>" >&2
    exit 64
fi

linux_sdk_root=$1
linux_amd64=$2
android_arm64=$3
android_amd64=$4
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
    if [ ! -d "$linux_sdk_root" ]; then
        echo "missing Linux SDK root: $linux_sdk_root" >&2
        exit 1
    fi
    if find "$linux_sdk_root" \
        \( -name 'libstdc++*' -o -name 'libstdcxx*' \) -print -quit \
        | grep -q .; then
        echo "Linux SDK exposes a forbidden libstdc++ artifact" >&2
        exit 1
    fi
    found_libcxx=0
    while IFS= read -r path; do
        description=$(/usr/bin/file "$path")
        case "$description" in
            *ELF*) reject_libstdcxx "$path" ;;
        esac
        case "$path" in
            */libc++.so.1) found_libcxx=1 ;;
        esac
    done <<EOF
$(find "$linux_sdk_root" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -111 \) -print)
EOF
    if [ "$found_libcxx" -ne 1 ]; then
        echo "Linux SDK does not ship libc++.so.1" >&2
        exit 1
    fi
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

require_file_description "$linux_amd64" "ELF 64-bit LSB pie executable, x86-64"
require_interpreter "$linux_amd64" "/lib64/ld-linux-x86-64.so.2"
reject_libstdcxx "$linux_amd64"
require_libcxx "$linux_amd64"
validate_linux_sdk_runtime

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
