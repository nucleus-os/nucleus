#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <destination> <package.deb>..." >&2
    exit 64
fi

destination=$1
shift
parent=$(dirname "$destination")
mkdir -p "$parent"
temporary=$(mktemp -d "$parent/.sysroot.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary/root"

for package in "$@"; do
    extraction=$(mktemp -d "$temporary/package.XXXXXX")
    (
        cd "$extraction"
        /usr/bin/ar -x "$package"
        archive=$(find . -maxdepth 1 -type f -name 'data.tar.*' -print -quit)
        if [ -z "$archive" ]; then
            echo "missing data archive in $package" >&2
            exit 1
        fi
        /usr/bin/tar -xf "$archive" -C "$temporary/root"
    )
    rm -rf "$extraction"
done

# Ubuntu Noble packages assume the distribution's merged-/usr root links. The
# package payloads do not own those filesystem-level links themselves.
ln -s usr/lib "$temporary/root/lib"
ln -s usr/lib64 "$temporary/root/lib64"

if find "$temporary/root" \
    \( -name 'libstdc++*' -o -name 'libstdcxx*' \) -print -quit \
    | grep -q .; then
    echo 'Linux target sysroot contains forbidden libstdc++ files' >&2
    exit 1
fi
test -d "$temporary/root/usr/include/c++/v1"
test -e "$temporary/root/usr/lib/x86_64-linux-gnu/libc++.so.1"
rm -rf "$destination"
mv "$temporary/root" "$destination"
trap - EXIT HUP INT TERM
rm -rf "$temporary"
