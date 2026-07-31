#!/usr/bin/env bash
set -euo pipefail

if [[ ! -x /src/swift/utils/build-script ]]; then
  echo "error: /src is not the complete read-only Swift sibling graph" >&2
  exit 64
fi
if [[ ! -d /build || ! -w /build ]]; then
  echo "error: /build is not the writable external build root" >&2
  exit 64
fi
if [[ ! -d /candidate || ! -w /candidate ]]; then
  echo "error: /candidate is not the writable candidate generation" >&2
  exit 64
fi

case "${1:-}" in
  host)
    mode="$1"
    shift
    ;;
  android | dependency)
    mode="$1"
    shift
    ;;
  *)
    echo "error: expected Swift builder mode: host, android, or dependency" >&2
    exit 64
    ;;
esac

if [[ $# -eq 0 ]]; then
  echo "error: Swift builder mode '$mode' has no command" >&2
  exit 64
fi

exec "$@"
