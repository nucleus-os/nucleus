#!/bin/bash
set -euo pipefail

# Moves the interactive account's retained Collider state into the machine-wide
# build store, once.
#
# The volume set is overwhelmingly live data whose reconstruction cost is the
# complete native dependency graph, so it is migrated rather than rebuilt. Every
# move is a rename on one filesystem: sparse allocation, clones, and volume
# images survive, and no copy of a terabyte is ever made. Run
# `collider cache reclaim` first so there is less to move.
#
# This is one-way. Everything it validates, it validates before the first move.

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"

if [[ $EUID -ne 0 || $# -gt 1 ]]; then
  echo "usage: sudo $0 [--dry-run]" >&2
  exit 64
fi
dry_run=false
[[ ${1:-} == "--dry-run" ]] && dry_run=true
readonly dry_run

contract_value() { /usr/bin/plutil -extract "$1" raw -o - "$contract"; }
fail() { echo "error: $*" >&2; exit 77; }
step() { echo "migrate: $*"; }

readonly builder_user="$(contract_value builder.user)"
readonly build_state_group="$(contract_value builder.buildStateGroup)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly container_service_label="$(contract_value launchd.label)"
readonly build_store=/Library/Nucleus/Collider
readonly developer_home="/Users/$developer_user"
readonly source_developer="$developer_home/Library/Developer/Nucleus/Collider"
readonly source_cache="$developer_home/Library/Caches/Nucleus/Collider"
readonly source_logs="$developer_home/Library/Logs/Nucleus/Collider"

# --- Preconditions -----------------------------------------------------------

# The store's existence is what switches every Collider consumer away from
# per-user storage, so this migration creates it and fills it in one pass. A
# store that existed while still empty would leave the retained volumes behind
# an owner that no longer addresses them.
[[ ! -e "$build_store" ]] \
  || fail "build store already exists; this migration runs once"
/usr/bin/dscl . -read "/Groups/$build_state_group" >/dev/null 2>&1 \
  || fail "build-state group is absent; run 'collider provision macos-builder commission' first"
/usr/sbin/dseditgroup -o checkmember -m "$developer_user" "$build_state_group" 2>/dev/null \
  | /usr/bin/grep -q 'yes' \
  || fail "$developer_user is not a member of $build_state_group"
[[ -d "$source_developer" ]] || fail "there is no interactive Collider state to migrate"

readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
if /usr/bin/pgrep -u "$builder_uid" -f Runner.Worker >/dev/null 2>&1; then
  fail "a job is executing on this runner; drain it before migrating"
fi

# A live API server holds its application root open and rewrites state beneath
# it, so both accounts' services stop before anything moves.
for service_uid in "$(/usr/bin/id -u "$developer_user")" "$builder_uid"; do
  for domain in "gui/$service_uid" "user/$service_uid"; do
    if /bin/launchctl print "$domain/$container_service_label" >/dev/null 2>&1; then
      $dry_run || /bin/launchctl bootout "$domain/$container_service_label" || true
    fi
  done
done
if ! $dry_run; then
  for _ in {1..50}; do
    /usr/bin/pgrep -f container-apiserver >/dev/null 2>&1 || break
    /bin/sleep 0.2
  done
  /usr/bin/pgrep -f container-apiserver >/dev/null 2>&1 \
    && fail "an Apple container API server is still running"
fi

readonly store_device="$(/usr/bin/stat -f '%d' "$build_store")"
for source_root in "$source_developer" "$source_cache" "$source_logs"; do
  [[ -d "$source_root" ]] || continue
  [[ "$(/usr/bin/stat -f '%d' "$source_root")" == "$store_device" ]] \
    || fail "source and store are on different filesystems: $source_root"
done

# --- What moves --------------------------------------------------------------
#
# Reconstructible state moves with everything else because it is live: the
# catalog's protected roots and the acquisitions whose only replacement path is
# the network are simply the parts that could not be rebuilt at all.

if ! $dry_run; then
  step "creating the build store"
  /usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$build_store")"
  /usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 2750 "$build_store"
  for store_directory in configuration state cache logs; do
    /usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 2750 \
      "$build_store/$store_directory"
  done
  # Signing material is the one subtree the reading group must not reach: the
  # identity that executes is the identity that signs.
  /usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 0700 \
    "$build_store/state/identity"
fi

move_into_store() {
  local source="$1" destination="$2"
  [[ -e "$source" ]] || return 0
  if [[ -e "$destination" ]]; then
    step "already present, leaving in place: $destination"
    return 0
  fi
  step "$source -> $destination"
  $dry_run && return 0
  /usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 2750 \
    "$(/usr/bin/dirname "$destination")"
  /bin/mv "$source" "$destination"
}

for subtree in apple-container build artifacts; do
  move_into_store "$source_developer/$subtree" "$build_store/state/$subtree"
done

# Commissioning already created the signing subtree with its restricted mode, so
# the keys move into it rather than replacing it. Leaving them behind would mint
# a second set on first use and strand every device flashed with the first.
if [[ -d "$source_developer/identity" ]] && ! $dry_run; then
  while IFS= read -r -d '' entry; do
    destination="$build_store/state/identity/$(/usr/bin/basename "$entry")"
    [[ -e "$destination" ]] || /bin/mv "$entry" "$destination"
  done < <(/usr/bin/find "$source_developer/identity" -mindepth 1 -maxdepth 1 -print0)
  /bin/rmdir "$source_developer/identity" 2>/dev/null || true
elif [[ -d "$source_developer/identity" ]]; then
  step "$source_developer/identity/* -> $build_store/state/identity/"
fi
move_into_store "$source_cache" "$build_store/cache-migrated"
move_into_store "$source_logs/runs" "$build_store/logs/runs"
readonly source_logs_service="$source_logs/service"
move_into_store "$source_logs_service" "$build_store/logs/service"

# The cache root moves as a whole and is then merged, because the store already
# declares its own cache directory.
if [[ -d "$build_store/cache-migrated" ]] && ! $dry_run; then
  while IFS= read -r -d '' entry; do
    destination="$build_store/cache/$(/usr/bin/basename "$entry")"
    [[ -e "$destination" ]] || /bin/mv "$entry" "$destination"
  done < <(/usr/bin/find "$build_store/cache-migrated" -mindepth 1 -maxdepth 1 -print0)
  /bin/rmdir "$build_store/cache-migrated" 2>/dev/null || true
fi

# The application root carries launchd service definitions naming the account
# that wrote them. The builder's service regenerates its own on start, so the
# stale ones are removed rather than migrated.
if ! $dry_run; then
  readonly migrated_app_root="$build_store/state/apple-container"
  /bin/rm -f "$migrated_app_root/apiserver/apiserver.plist"
  while IFS= read -r -d '' stale_service; do
    /bin/rm -f "$stale_service"
  done < <(/usr/bin/find "$migrated_app_root" -name service.plist -print0 2>/dev/null)
fi

# --- Volume identity ---------------------------------------------------------
#
# A volume records its owner in its directory name, its `name` field, its
# `source` path, and one label. All four move from the checkout that created it
# to the store that now owns it.

readonly volumes="$build_store/state/apple-container/volumes"
readonly previous_owner="$(/usr/bin/printf '%s' "$checkout" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
readonly current_owner="$(/usr/bin/printf '%s' "$build_store" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
step "workspace owner $previous_owner -> $current_owner"

if [[ -d "$volumes" ]]; then
  while IFS= read -r -d '' volume; do
    name="$(/usr/bin/basename "$volume")"
    [[ "$name" == *"$previous_owner"* ]] || continue
    renamed="${name//$previous_owner/$current_owner}"
    step "  $name -> $renamed"
    $dry_run && continue
    /bin/mv "$volume" "$volumes/$renamed"
    /usr/bin/python3 - "$volumes/$renamed/entity.json" "$previous_owner" "$current_owner" \
      "$volumes/$renamed/volume.img" <<'PYTHON'
import json, sys
path, previous, current, image = sys.argv[1:5]
with open(path) as handle:
    entity = json.load(handle)
entity["name"] = entity["name"].replace(previous, current)
entity["source"] = image
labels = entity.get("labels", {})
for key, value in labels.items():
    if value == previous:
        labels[key] = current
entity["labels"] = labels
with open(path, "w") as handle:
    json.dump(entity, handle)
PYTHON
  done < <(/usr/bin/find "$volumes" -mindepth 1 -maxdepth 1 -type d -print0)
fi

if $dry_run; then
  step "dry run complete; nothing moved"
  exit 0
fi

# --- Ownership and verification ----------------------------------------------

step "assigning store ownership"
/usr/sbin/chown -R "$builder_user":"$build_state_group" "$build_store"
/bin/chmod 0700 "$build_store/state/identity"

step "verifying migrated volumes"
if [[ -d "$volumes" ]]; then
  while IFS= read -r -d '' volume; do
    entity="$volume/entity.json"
    [[ -f "$entity" ]] || fail "migrated volume has no metadata: $volume"
    /usr/bin/python3 - "$entity" "$volume" "$previous_owner" <<'PYTHON'
import json, os, sys
path, directory, previous = sys.argv[1:4]
with open(path) as handle:
    entity = json.load(handle)
name = os.path.basename(directory)
problems = []
if entity.get("name") != name:
    problems.append(f"name {entity.get('name')!r} does not match directory {name!r}")
if entity.get("source") != os.path.join(directory, "volume.img"):
    problems.append(f"source {entity.get('source')!r} does not address this volume")
if not os.path.exists(os.path.join(directory, "volume.img")):
    problems.append("volume image is absent")
if previous in json.dumps(entity):
    problems.append("metadata still records the previous owner")
if problems:
    sys.exit("; ".join(problems))
PYTHON
  done < <(/usr/bin/find "$volumes" -mindepth 1 -maxdepth 1 -type d -print0)
fi

for stale in "$source_developer" "$source_cache"; do
  if [[ -d "$stale" ]] && [[ -n "$(/usr/bin/find "$stale" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "state remains at the previous location: $stale"
  fi
done

step "migration complete; start the builder container service to adopt the store"
