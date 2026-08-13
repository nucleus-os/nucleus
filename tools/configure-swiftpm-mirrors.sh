#!/usr/bin/env bash
# Make every SwiftPM edge to a root-owned source dependency resolve to the
# checkout pinned by the Nucleus gitlink. The generated configuration is local
# to the clone because file URLs are necessarily absolute.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

configure_package() {
  local package="$1"
  local configuration="$package/.swiftpm/configuration/mirrors.json"
  if [[ -f "$configuration" ]] \
      && grep -Fq "file://$root/third-party/containerization" "$configuration" \
      && grep -Fq "file://$root/third-party/swift-argument-parser" "$configuration" \
      && grep -Fq "file://$root/third-party/swift-crypto" "$configuration" \
      && grep -Fq "file://$root/third-party/swift-log" "$configuration" \
      && grep -Fq '"original" : "https://github.com/nucleus-os/swift-subprocess.git"' "$configuration" \
      && grep -Fq '"original" : "https://github.com/nucleus-os/swift-system.git"' "$configuration" \
      && grep -Fq "file://$root/third-party/swift-system" "$configuration" \
      ; then
    return
  fi
  local original mirror
  while IFS='|' read -r original mirror; do
    swift package --package-path "$package" config unset-mirror \
      --original "$original" >/dev/null 2>&1 || true
    swift package --package-path "$package" config set-mirror \
      --original "$original" \
      --mirror "file://$root/third-party/$mirror" >/dev/null
  done <<'MIRRORS'
https://github.com/apple/containerization.git|containerization
https://github.com/apple/swift-argument-parser.git|swift-argument-parser
https://github.com/apple/swift-crypto.git|swift-crypto
https://github.com/apple/swift-log.git|swift-log
https://github.com/apple/swift-system|swift-system
https://github.com/apple/swift-system.git|swift-system
https://github.com/nucleus-os/swift-subprocess.git|swift-subprocess
https://github.com/nucleus-os/swift-system.git|swift-system
MIRRORS
}

configure_package "$root/collider"
configure_package "$root/collider/engine"
