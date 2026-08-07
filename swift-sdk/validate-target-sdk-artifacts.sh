#!/bin/sh
set -eu

if [ "$#" -ne 7 ]; then
    echo "usage: $0 <linux-sdk-root> <linux-sdk-directory> <minimum-glibc> <linux-arm64> <linux-amd64> <android-arm64> <android-amd64>" >&2
    exit 64
fi

linux_sdk_root=$1
linux_sdk_directory=$2
minimum_glibc=$3
linux_arm64=$4
linux_amd64=$5
android_arm64=$6
android_amd64=$7
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

reject_newer_glibc_imports() {
    path=$1
    newer=$(
        "$llvm_objdump" -T "$path" 2>/dev/null \
            | awk -v maximum="$minimum_glibc" '
                $0 ~ /\*UND\*/ && match($0, /GLIBC_[0-9]+\.[0-9]+/) {
                    version = substr($0, RSTART + 6, RLENGTH - 6)
                    split(version, found, ".")
                    split(maximum, allowed, ".")
                    if (found[1] > allowed[1] \
                        || (found[1] == allowed[1] && found[2] > allowed[2])) {
                        print "GLIBC_" version
                        exit
                    }
                }
            '
    )
    if [ -n "$newer" ]; then
        echo "$path imports $newer, newer than GLIBC_$minimum_glibc" >&2
        exit 1
    fi
}

validate_linux_sdk_runtime() {
    triple=$1
    description_pattern=$2
    triple_root="$linux_sdk_root/swift-linux/$triple"
    target_root="$triple_root/$linux_sdk_directory"
    toolset="$linux_sdk_root/swift-linux/$triple/toolset.json"
    if [ ! -f "$toolset" ]; then
        echo "missing Linux SDK toolset: $toolset" >&2
        exit 1
    fi
    /usr/bin/python3 - "$toolset" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    toolset = json.load(stream)
linker_path = toolset.get("linker", {}).get("path")
if linker_path is not None:
    raise SystemExit(f"Linux SDK embeds an execution-environment-specific linker: {path}")
PY
    bundled_linker="$linux_sdk_root/swift-linux/$triple/swift.xctoolchain/usr/bin/ld.lld"
    if [ -e "$bundled_linker" ] || [ -L "$bundled_linker" ]; then
        echo "Linux SDK bundles an execution-environment-specific ld.lld for $triple" >&2
        exit 1
    fi
    if [ ! -d "$target_root" ]; then
        echo "missing Linux SDK target root: $target_root" >&2
        exit 1
    fi
    /usr/bin/python3 - "$linux_sdk_root/swift-linux/swift-sdk.json" \
        "$triple_root/swift-sdk.json" "$triple" "$linux_sdk_directory" <<'PY'
import json
import sys

root_path, triple_path, triple, sdk_directory = sys.argv[1:]
for path, key in ((root_path, triple), (triple_path, triple)):
    with open(path, encoding="utf-8") as stream:
        metadata = json.load(stream)
    target = metadata["targetTriples"][key]
    sdk_root = target["sdkRootPath"]
    if not sdk_root.endswith(sdk_directory):
        raise SystemExit(f"Linux SDK metadata has the wrong SDK root: {path}: {sdk_root}")
    if "ubuntu" in json.dumps(metadata).lower():
        raise SystemExit(f"Linux SDK metadata exposes its assembly distribution: {path}")
PY
    if find "$target_root" \
        \( -name 'libstdc++*' -o -name 'libstdcxx*' \) -print -quit \
        | grep -q .; then
        echo "Linux SDK exposes a forbidden libstdc++ artifact" >&2
        exit 1
    fi
    while IFS= read -r path; do
        description=$(/usr/bin/file "$path")
        case "$description" in
            *ELF*)
                reject_libstdcxx "$path"
                case "$path" in
                    */usr/lib/swift/*|*/libc++.so.*|*/libc++abi.so.*|*/libunwind.so.*)
                        reject_newer_glibc_imports "$path"
                        ;;
                esac
                ;;
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
    if ! grep -F -- '-module-abi-name Testing_toolchain' "$testing_module" >/dev/null; then
        echo "Linux SDK Swift Testing module does not use the toolchain ABI identity for $triple" >&2
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
reject_newer_glibc_imports "$linux_arm64"

require_file_description "$linux_amd64" "ELF 64-bit LSB pie executable, x86-64"
require_interpreter "$linux_amd64" "/lib64/ld-linux-x86-64.so.2"
reject_libstdcxx "$linux_amd64"
require_libcxx "$linux_amd64"
reject_newer_glibc_imports "$linux_amd64"
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
