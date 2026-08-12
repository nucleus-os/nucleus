#!/bin/sh
set -eu

snapshot=${NUCLEUS_UBUNTU_SNAPSHOT:?}
suites=${NUCLEUS_UBUNTU_SUITES:?}
root=/tmp/nucleus-apt-resolution
lists="$root/lists"
sources="$root/sources.list"
status="$root/status"
catalog="$root/catalog.tsv"

rm -rf "$root"
mkdir -p "$lists/partial"
: > "$status"

for suite in $suites; do
    for component in main universe; do
        for architecture in arm64 amd64; do
            source="/indexes/${suite}_${component}_${architecture}.Packages.gz"
            destination="$lists/snapshot.ubuntu.com_ubuntu_${snapshot}_dists_${suite}_${component}_binary-${architecture}_Packages"
            test -f "$source"
            gzip -dc "$source" > "$destination"
        done
    done
done

awk -v snapshot="$snapshot" '
    BEGIN { RS=""; FS="\n" }
    {
        filename=""; size=""; sha256=""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Filename: /) filename=substr($i, 11)
            if ($i ~ /^Size: /) size=substr($i, 7)
            if ($i ~ /^SHA256: /) sha256=substr($i, 9)
        }
        if (filename != "" && size != "" && sha256 != "") {
            print "https://snapshot.ubuntu.com/ubuntu/" snapshot "/" filename "\t" size "\t" sha256
        }
    }
' "$lists"/*_Packages | sort -u > "$catalog"

: > "$sources"
for suite in $suites; do
    printf 'deb [arch=arm64,amd64 trusted=yes] https://snapshot.ubuntu.com/ubuntu/%s %s main universe\n' \
        "$snapshot" "$suite" >> "$sources"
done

apt_options="
    -o Dir::Etc::sourcelist=$sources
    -o Dir::Etc::sourceparts=-
    -o Dir::State::lists=$lists
    -o Dir::State::status=$status
    -o APT::Architecture=arm64
    -o APT::Architectures::=arm64
    -o APT::Architectures::=amd64
    -o Acquire::Languages=none
"

# shellcheck disable=SC2086
apt-get $apt_options --yes --no-install-recommends --print-uris \
    install $(grep -Ev '^[[:space:]]*(#|$)' /input/apt-install-packages.txt) \
    > /output/install-uris.txt

# These packages intentionally remain uninstalled because Ubuntu's arm64 and
# amd64 libc++ packages contain colliding versioned LLVM paths. The final image
# extracts only their amd64 runtime objects.
# shellcheck disable=SC2086
apt-get $apt_options --yes --print-uris \
    download $(grep -Ev '^[[:space:]]*(#|$)' /input/apt-extract-packages.txt) \
    > /output/extract-uris.txt

: > /output/packages.tsv
for role in install extract; do
    sed -n "s/^'\([^']*\)'.*/\1/p" "/output/$role-uris.txt" \
        | while IFS= read -r encoded_url; do
            escaped_url=$(printf '%s' "$encoded_url" | sed 's/%/\\x/g')
            url=$(printf '%b' "$escaped_url")
            record=$(awk -F '\t' -v url="$url" '$1 == url { print; exit }' "$catalog")
            test -n "$record"
            printf '%s\t%s\n' "$role" "$record"
        done >> /output/packages.tsv
done
sort -u -o /output/packages.tsv /output/packages.tsv
