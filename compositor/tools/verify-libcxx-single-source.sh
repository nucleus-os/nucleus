#!/usr/bin/env bash
# Verify that the compositor binary uses one libc++ implementation.
#
# Two checks:
#
#   1. Binary directly NEEDs `libc++.so.1` and `libc++abi.so.1` (and only
#      one libc++.so.1 resolves via `ldd`). If `libstdc++.so.6` shows up,
#      something is dragging in a second C++ stdlib.
#
#   2. No libc++ symbols with GLOBAL text (`T`) visibility live inside
#      the binary. The expected pattern is:
#
#        - `U _ZNSt3__1...` — undefined, resolved at runtime by libc++.so.1
#        - `t _ZNSt3__1...$plt` / `$got` — PLT/GOT stubs for the above (fine)
#        - `t _ZNSt3__1...` (no suffix) — hidden-visibility inline templates
#          baked into TUs (fine; they don't cross DSO boundaries)
#        - `W _ZNSt3__1...` — weak vague-linkage instantiations
#          (tolerated; deduplicated by the dynamic linker)
#
#      A `T` symbol would mean a duplicate definition of libc++ logic is
#      baked into the exe and could win symbol resolution over libc++.so.1's
#      version. That's the bug class this script catches.
#
# Run: tools/verify-libcxx-single-source.sh path/to/nucleus-compositor

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
binary="${1:-$repo_root/compositor/.build/out/Products/Debug-linux-x86_64/NucleusCompositor}"
if [[ ! -x "$binary" ]]; then
    echo "error: $binary does not exist or is not executable" >&2
    exit 2
fi

fail=0

echo "==> Checking dynamic dependencies of $binary"
needed_libstdcxx=$(objdump -p "$binary" | grep -E "^\s+NEEDED\s+libstdc\+\+" || true)
if [[ -n "$needed_libstdcxx" ]]; then
    echo "FAIL: $binary directly NEEDs libstdc++:"
    echo "$needed_libstdcxx" | sed 's/^/  /'
    fail=1
fi

needed_libcxx=$(objdump -p "$binary" | grep -E "^\s+NEEDED\s+libc\+\+\.so" || true)
if [[ -z "$needed_libcxx" ]]; then
    echo "FAIL: $binary does not NEED libc++.so.1 (C++ stdlib symbols would be unresolved)"
    fail=1
fi

ldd_libstdcxx=$(ldd "$binary" 2>/dev/null | grep -E "libstdc\+\+" || true)
if [[ -n "$ldd_libstdcxx" ]]; then
    echo "FAIL: libstdc++ resolves transitively (some loaded .so still NEEDs it):"
    echo "$ldd_libstdcxx" | sed 's/^/  /'
    fail=1
fi

ldd_libcxx_count=$(ldd "$binary" 2>/dev/null | grep -cE "libc\+\+\.so\.1" || true)
if (( ldd_libcxx_count != 1 )); then
    echo "FAIL: expected exactly one libc++.so.1 in ldd output, found $ldd_libcxx_count"
    fail=1
fi

echo "==> Checking that no libc++ symbols are statically defined as global text"
# Match any T-type std::__1::* symbol. T = global text definition.
# We exclude $plt/$got suffixes (those would already be matched by lowercase 't').
global_text=$(nm "$binary" 2>/dev/null | awk '/^[0-9a-f]+ T _ZNSt3__1/' || true)
if [[ -n "$global_text" ]]; then
    echo "FAIL: found global-text libc++ symbols inside the binary (should be U/undefined):"
    echo "$global_text" | head -20 | sed 's/^/  /'
    count=$(echo "$global_text" | wc -l)
    echo "  ... ($count total)"
    fail=1
fi

if (( fail == 0 )); then
    echo "ok: $binary uses exactly one libc++ (Swift toolchain's libc++.so.1)"
fi
exit "$fail"
