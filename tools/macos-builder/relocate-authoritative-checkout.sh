#!/bin/bash
# Moves the authoritative checkout out of the developer's home.
#
# The checkout is state two accounts share, and shared state belongs to neither
# home. While it lived in one, the builder needed a traverse grant on that home
# and a deny entry on every sibling to contain it, and it still could not
# resolve the checkout's own absolute path: a directory it may search but not
# read cannot be named, so any tool calling getcwd() inside a root-package build
# failed. Moving it to a root-owned, world-readable parent removes both the
# mechanism and the fault.
#
# One-time. After it succeeds, provisioning maintains the new layout.
set -euo pipefail

readonly script_directory="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd -P)"
readonly contract="$script_directory/contract.json"

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}

if [[ $EUID -ne 0 ]]; then
  echo "error: run this relocation through sudo" >&2
  exit 77
fi

# This script and the contract it reads both live in the tree it is about to
# move, and bash reads a script incrementally: relocating the file out from
# under the interpreter mid-read truncates execution at an arbitrary line.
# Continue from a staged copy of both, before reading either, so nothing this
# run depends on can move underneath it.
if [[ "${NUCLEUS_RELOCATION_STAGED:-}" != 1 ]]; then
  staging="$(/usr/bin/mktemp -d /tmp/nucleus-relocate.XXXXXX)"
  /bin/cp "$script_directory/$(/usr/bin/basename "$0")" "$staging/relocate.sh"
  /bin/cp "$contract" "$staging/contract.json"
  /bin/chmod 0700 "$staging/relocate.sh"
  NUCLEUS_RELOCATION_STAGED=1 exec "$staging/relocate.sh" "$@"
fi

# Every later step either removes the developer home's access entries or runs a
# command as the builder, and a child inherits this working directory. Standing
# in the home would leave those children unable to resolve their own current
# directory the moment the entries are gone -- the exact fault this relocation
# exists to remove.
cd /

readonly destination="$(contract_value builder.authoritativeCheckout)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly builder_user="$(contract_value builder.user)"
readonly contract_root="$(contract_value builder.hostContractRoot)"
readonly record="$contract_root/authoritative-checkout"
readonly lease="$(contract_value builder.hostExecutionLock)"

[[ -f "$record" ]] || { echo "error: builder checkout contract is not installed" >&2; exit 72; }
readonly source="$(/usr/bin/sed -n '1p' "$record")"
[[ "$destination" != "/Users/"* ]] \
  || { echo "error: destination must not live in a user home" >&2; exit 78; }

# Each step is applied only where it is not already true, so a run interrupted
# partway is completed by running it again rather than needing its remaining
# steps performed by hand.
if [[ -d "$destination" && ! -L "$destination" ]]; then
  echo "checkout is already at $destination; completing the remaining steps"
else
  [[ -d "$source" ]] || { echo "error: recorded checkout does not exist: $source" >&2; exit 72; }
  [[ ! -e "$destination" ]] || { echo "error: destination exists but is not the checkout" >&2; exit 73; }
  [[ -f "$source/Package.swift" ]] \
    || { echo "error: recorded checkout is not a Nucleus clone" >&2; exit 72; }

  # A build holding the lease is reading the tree this is about to rename.
  if [[ -s "$lease" ]]; then
    echo "error: a Collider run holds the execution lease; wait for it to finish" >&2
    /usr/bin/sed -n '1,3p' "$lease" >&2
    exit 75
  fi

  echo "moving $source -> $destination"
  /usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$destination")"
  # Same volume, so this is a rename: atomic, and it carries ownership, modes,
  # and the inheritable access-control entry that makes the tree read-only to
  # the builder. A cross-volume fallback would silently copy 100+ GB, so refuse.
  /bin/mv "$source" "$destination" \
    || { echo "error: rename failed; destination must share the source volume" >&2; exit 74; }
fi
[[ -f "$destination/Package.swift" ]] \
  || { echo "error: $destination is not a Nucleus clone" >&2; exit 72; }
/bin/chmod 0755 "$destination"

# Daily ergonomics: the old path keeps working for shells, editors, and SSH
# remotes. Collider resolves the physical path, so the symlink never becomes a
# second identity for the same tree.
if [[ ! -e "$source" && ! -L "$source" ]]; then
  /usr/bin/sudo -u "$developer_user" /bin/ln -s "$destination" "$source"
fi

printf '%s\n' "$destination" >"$record"
/usr/sbin/chown root:wheel "$record"
/bin/chmod 0644 "$record"

# The builder no longer reaches the home at all, so every entry that existed to
# grant and then contain that reach is removed. Entries are removed by exact
# match and may legitimately be absent, so failures here are not fatal.
readonly home="/Users/$developer_user"
/bin/chmod -a "$builder_user allow search" "$home" 2>/dev/null || true
/bin/chmod -a "$builder_user allow search" "$home/Developer" 2>/dev/null || true
while IFS= read -r -d '' entry; do
  /bin/chmod -h -a "$builder_user deny read,write,execute,delete" "$entry" 2>/dev/null || true
done < <(/usr/bin/find "$home" -mindepth 1 -maxdepth 1 -print0)
while IFS= read -r -d '' entry; do
  /bin/chmod -h -a "$builder_user deny read,write,execute,delete" "$entry" 2>/dev/null || true
done < <(/usr/bin/find "$home/Developer" -mindepth 1 -maxdepth 1 -print0)

readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
run_as_builder() {
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" "$@"
}
run_as_builder /usr/bin/git config --global --replace-all safe.directory "$destination"
run_as_builder /usr/bin/git config --global --add safe.directory "$destination/*"

# Every check reports rather than aborting, so one failure does not hide the
# rest: the move has already happened and the complete picture is what tells
# the operator whether it landed correctly.
echo
echo "relocated. verifying builder access:"
failures=0
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok      $description"
  else
    echo "  FAILED  $description" >&2
    failures=$((failures + 1))
  fi
}
refute() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAILED  $description" >&2
    failures=$((failures + 1))
  else
    echo "  ok      $description"
  fi
}

check "builder reads the checkout" \
  run_as_builder /bin/test -r "$destination/Package.swift"
# The fault that motivated the move: resolving the tree's own absolute path.
check "builder resolves the checkout path" \
  run_as_builder /bin/sh -c "cd '$destination' && pwd -P"
check "builder reads Git history" \
  run_as_builder /usr/bin/git -C "$destination" rev-parse HEAD
refute "builder cannot write the checkout" \
  run_as_builder /usr/bin/touch "$destination/.relocation-write-probe"
# Removed unconditionally: if the probe unexpectedly succeeded it left a file
# in the tree, and that is the case where cleanup matters most.
/bin/rm -f "$destination/.relocation-write-probe"
refute "builder cannot list the developer home" \
  run_as_builder /bin/ls "$home"
refute "builder cannot list the old parent" \
  run_as_builder /bin/ls "$home/Developer"

if [[ $failures -ne 0 ]]; then
  echo >&2
  echo "error: $failures access check(s) failed; report this before building" >&2
  exit 70
fi
echo
echo "authoritative checkout is now $destination"
echo "next: sudo $destination/tools/macos-builder/finalize-nucleus-builder.sh"
