#!/usr/bin/env bash
# Make every SwiftPM edge to a root-owned source dependency resolve to the
# checkout pinned by the Nucleus gitlink. The generated configuration lives in
# caller-owned host state because a builder may consume the checkout read-only.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration_root="${NUCLEUS_SWIFTPM_CONFIG_ROOT:-}"
if [[ -z "$configuration_root" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then
    configuration_root="$HOME/Library/Application Support/Nucleus/Collider/swiftpm/configuration"
  else
    configuration_root="${XDG_CONFIG_HOME:-$HOME/.config}/nucleus/collider/swiftpm"
  fi
fi
mkdir -p "$configuration_root"

configure_package() {
  local package="$1"
  local configuration="$configuration_root/mirrors.json"
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
    swift package --package-path "$package" --config-path "$configuration_root" \
      config unset-mirror \
      --original "$original" >/dev/null 2>&1 || true
    swift package --package-path "$package" --config-path "$configuration_root" \
      config set-mirror \
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
