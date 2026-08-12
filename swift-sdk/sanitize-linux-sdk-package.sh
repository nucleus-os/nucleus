#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <input.deb> <output.deb>" >&2
    exit 64
fi

input=$1
output=$2
output_parent=$(dirname "$output")
mkdir -p "$output_parent"
temporary=$(mktemp -d "$output_parent/.sanitize.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

(
    cd "$temporary"
    /usr/bin/ar -x "$input"
)
data_archive=$(find "$temporary" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)
control_archive=$(find "$temporary" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)
if [ -z "$data_archive" ] || [ -z "$control_archive" ] \
    || [ ! -f "$temporary/debian-binary" ]; then
    echo "invalid Debian package: $input" >&2
    exit 1
fi

mkdir -p "$temporary/root"
/usr/bin/tar -xf "$data_archive" -C "$temporary/root" \
    --exclude './usr/share/man' \
    --exclude './usr/share/man/*' \
    --exclude './usr/include/linux/netfilter/xt_CONNMARK.h' \
    --exclude './usr/include/linux/netfilter/xt_connmark.h' \
    --exclude './usr/include/linux/netfilter/xt_DSCP.h' \
    --exclude './usr/include/linux/netfilter/xt_dscp.h' \
    --exclude './usr/include/linux/netfilter/xt_MARK.h' \
    --exclude './usr/include/linux/netfilter/xt_mark.h' \
    --exclude './usr/include/linux/netfilter/xt_RATEEST.h' \
    --exclude './usr/include/linux/netfilter/xt_rateest.h' \
    --exclude './usr/include/linux/netfilter/xt_TCPMSS.h' \
    --exclude './usr/include/linux/netfilter/xt_tcpmss.h' \
    --exclude './usr/include/linux/netfilter_ipv4/ipt_ECN.h' \
    --exclude './usr/include/linux/netfilter_ipv4/ipt_ecn.h' \
    --exclude './usr/include/linux/netfilter_ipv4/ipt_TTL.h' \
    --exclude './usr/include/linux/netfilter_ipv4/ipt_ttl.h' \
    --exclude './usr/include/linux/netfilter_ipv6/ip6t_HL.h' \
    --exclude './usr/include/linux/netfilter_ipv6/ip6t_hl.h'

# Nucleus's target SDK is a compiler sysroot, not a general Linux development
# installation. Manual pages are never compiler inputs. Nucleus does not expose
# the eight case-colliding netfilter target/match interfaces above; the rest of
# the kernel UAPI remains intact. Excluding both variants of only those unused
# interfaces removes the compiler-input collisions in the pinned Ubuntu package
# closure and lets the reproducible SDK live on the default case-insensitive
# macOS filesystem.
rm -f "$temporary"/data.tar.*
/usr/bin/tar -czf "$temporary/data.tar.gz" -C "$temporary/root" .

temporary_output="$output_parent/.${output##*/}.tmp.$$"
rm -f "$temporary_output"
(
    cd "$temporary"
    /usr/bin/ar -rcS "$temporary_output" \
        debian-binary "${control_archive##*/}" data.tar.gz
)
mv -f "$temporary_output" "$output"
trap - EXIT HUP INT TERM
rm -rf "$temporary"
