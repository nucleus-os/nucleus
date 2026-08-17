#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"

if [[ $EUID -eq 0 ]]; then
  echo "error: run preparation as the interactive developer, without sudo" >&2
  exit 77
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 64
fi

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}

readonly expected_user="$(contract_value builder.developerUser)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly version="$(contract_value builder.runnerVersion)"
readonly url="$(contract_value builder.runnerArchiveURL)"
readonly expected_sha="$(contract_value builder.runnerArchiveSHA256)"
readonly expected_size="$(contract_value builder.runnerArchiveSize)"
readonly cache_root="$HOME/Library/Caches/Nucleus/Collider/provisioning"
readonly archive="$cache_root/actions-runner-osx-arm64-$version.tar.gz"

if [[ $(/usr/bin/id -un) != "$expected_user" ]]; then
  echo "error: preparation must run as $expected_user" >&2
  exit 77
fi
readonly canonical_checkout="$(cd "$checkout" && /bin/pwd -P)"
if [[ "$canonical_checkout" != "$checkout" || ! -f "$checkout/Package.swift" ]]; then
  echo "error: authoritative checkout does not match the host contract: $checkout" >&2
  exit 72
fi

/usr/bin/install -d -m 0755 "$cache_root"
if [[ ! -f "$archive" ]]; then
  temporary="$archive.partial.$$"
  trap '/bin/rm -f "$temporary"' EXIT
  /usr/bin/curl --fail --location --show-error "$url" --output "$temporary"
  /bin/mv "$temporary" "$archive"
  trap - EXIT
fi

actual_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
actual_size="$(/usr/bin/stat -f '%z' "$archive")"
if [[ "$actual_sha" != "$expected_sha" || "$actual_size" != "$expected_size" ]]; then
  echo "error: pinned GitHub Actions runner archive failed verification" >&2
  echo "error: expected $expected_sha / $expected_size bytes" >&2
  echo "error: found    $actual_sha / $actual_size bytes" >&2
  exit 65
fi

echo "prepared and verified GitHub Actions runner $version"
echo "archive: $archive"
echo "handoff: gh auth refresh -h github.com -s admin:org"
echo "then: $script_directory/handoff-nucleus-builder.sh"
