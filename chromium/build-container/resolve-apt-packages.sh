#!/bin/sh
set -eu

snapshot=20260730T000000Z
root=/tmp/nucleus-apt-resolution
lists="$root/lists"
sources="$root/sources.list"
status="$root/status"
catalog="$root/catalog.tsv"

rm -rf "$root"
mkdir -p "$lists/partial"
: > "$status"

for suite in resolute resolute-updates resolute-security; do
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

cat > "$sources" <<EOF
deb [arch=arm64,amd64 trusted=yes] https://snapshot.ubuntu.com/ubuntu/$snapshot resolute main universe
deb [arch=arm64,amd64 trusted=yes] https://snapshot.ubuntu.com/ubuntu/$snapshot resolute-updates main universe
deb [arch=arm64,amd64 trusted=yes] https://snapshot.ubuntu.com/ubuntu/$snapshot resolute-security main universe
EOF

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
    install $(grep -Ev '^[[:space:]]*(#|$)' /input/packages.txt) \
    > /output/install-uris.txt

: > /output/packages.tsv
sed -n "s/^'\([^']*\)'.*/\1/p" /output/install-uris.txt \
    | while IFS= read -r encoded_url; do
        escaped_url=$(printf '%s' "$encoded_url" | sed 's/%/\\x/g')
        url=$(printf '%b' "$escaped_url")
        record=$(awk -F '\t' -v url="$url" '$1 == url { print; exit }' "$catalog")
        test -n "$record"
        printf 'install\t%s\n' "$record"
    done >> /output/packages.tsv
sort -u -o /output/packages.tsv /output/packages.tsv
