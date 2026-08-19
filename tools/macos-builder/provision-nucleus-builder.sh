#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"

if [[ $EUID -ne 0 || $# -ne 1 ]]; then
  echo "usage: sudo $0 <verified-runner-archive>  # registration token on stdin" >&2
  exit 64
fi
IFS= read -r registration_token
if [[ -z "$registration_token" ]]; then
  echo "error: a short-lived GitHub runner registration token is required on stdin" >&2
  exit 65
fi
trap 'registration_token=' EXIT

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}

# Commands run as the builder inherit this working directory, and the builder
# reaches exactly one tree: the checkout. Invoked from anywhere else -- a
# developer home most of all -- those children could not resolve their own
# current directory. Anchor somewhere every identity on this host can read.
cd /

run_as_builder() {
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" "$@"
}

readonly archive="$1"
readonly builder_user="$(contract_value builder.user)"
readonly builder_group="$(contract_value builder.group)"
readonly builder_home="$(contract_value builder.home)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly organization="$(contract_value builder.organization)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_label="$(contract_value builder.runnerLabel)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly expected_sha="$(contract_value builder.runnerArchiveSHA256)"
readonly expected_size="$(contract_value builder.runnerArchiveSize)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly runner_root="$(contract_value builder.runnerRoot)"
readonly host_contract_root="$(contract_value builder.hostContractRoot)"
readonly runner_work_root="$(contract_value builder.runnerWorkRoot)"
readonly runner_plist="/Library/LaunchDaemons/$runner_service_label.plist"

for declared_path in "$runner_root" "$host_contract_root" "$runner_work_root"; do
  if [[ "$declared_path" != /* || "$declared_path" =~ [[:space:]] ]]; then
    echo "error: declared builder root must be absolute and free of whitespace" >&2
    echo "error: the Actions runner passes step-script paths to the shell unquoted" >&2
    exit 78
  fi
done

actual_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
actual_size="$(/usr/bin/stat -f '%z' "$archive")"
if [[ "$actual_sha" != "$expected_sha" || "$actual_size" != "$expected_size" ]]; then
  echo "error: runner archive does not match the pinned contract" >&2
  exit 65
fi
if [[ "$(cd "$checkout" && /bin/pwd -P)" != "$checkout" ]]; then
  echo "error: authoritative checkout is not canonical: $checkout" >&2
  exit 72
fi

runner_staging_state=fresh
if [[ -e "$runner_root" || -L "$runner_root" ]]; then
  [[ ! -L "$runner_root" && -d "$runner_root" ]] \
    || { echo "error: runner staging root is not a directory" >&2; exit 73; }
  [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_root") == "$builder_user:$builder_group:755" ]] \
    || { echo "error: runner staging root ownership or mode drifted" >&2; exit 73; }
  if [[ -z "$(/usr/bin/find "$runner_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    runner_staging_state=fresh
  elif [[ -x "$runner_root/config.sh" ]] \
      && [[ ! -e "$runner_root/.runner" && ! -L "$runner_root/.runner" ]] \
      && [[ ! -e "$runner_root/.credentials" && ! -L "$runner_root/.credentials" ]] \
      && [[ ! -e "$host_contract_root" && ! -L "$host_contract_root" ]] \
      && [[ ! -e "$runner_plist" && ! -L "$runner_plist" ]] \
      && [[ ! -e /usr/local/bin/collider && ! -L /usr/local/bin/collider ]] \
      && [[ ! -e /usr/local/bin/nucleus-builder-run && ! -L /usr/local/bin/nucleus-builder-run ]]; then
    runner_staging_state=unregistered
  else
    echo "error: runner state exists beyond recoverable unregistered staging" >&2
    exit 73
  fi
fi
readonly runner_staging_state

# The builder's own primary group is what makes the source boundary an allow
# list. A member of staff would inherit read access to the whole interactive
# home, which is mode 0750 and staff-readable, and every restriction would then
# have to be enumerated and kept current.
if /usr/bin/dscl . -read "/Groups/$builder_group" >/dev/null 2>&1; then
  builder_gid="$(/usr/bin/dscl . -read "/Groups/$builder_group" PrimaryGroupID \
    | /usr/bin/awk '{print $2}')"
  [[ "$builder_gid" -ge 501 && "$builder_gid" -lt 1000 ]] \
    || { echo "error: existing builder GID is outside the local service range" >&2; exit 77; }
else
  maximum_gid="$(/usr/bin/dscl . -list /Groups PrimaryGroupID \
    | /usr/bin/awk '$2 >= 501 && $2 < 1000 {print $2}' \
    | /usr/bin/sort -n | /usr/bin/tail -1)"
  builder_gid="$(( ${maximum_gid:-500} + 1 ))"
  /usr/bin/dscl . -create "/Groups/$builder_group"
  /usr/bin/dscl . -create "/Groups/$builder_group" RealName "Nucleus Builder"
  /usr/bin/dscl . -create "/Groups/$builder_group" PrimaryGroupID "$builder_gid"
  /usr/bin/dscl . -create "/Groups/$builder_group" Password '*'
fi
readonly builder_gid

if ! /usr/bin/dscl . -read "/Users/$builder_user" >/dev/null 2>&1; then
  maximum_uid="$(/usr/bin/dscl . -list /Users UniqueID \
    | /usr/bin/awk '$2 >= 501 && $2 < 1000 {print $2}' \
    | /usr/bin/sort -n | /usr/bin/tail -1)"
  builder_uid="$(( ${maximum_uid:-500} + 1 ))"
  /usr/bin/dscl . -create "/Users/$builder_user"
  /usr/bin/dscl . -create "/Users/$builder_user" RealName "Nucleus Builder"
  /usr/bin/dscl . -create "/Users/$builder_user" UniqueID "$builder_uid"
  /usr/bin/dscl . -create "/Users/$builder_user" PrimaryGroupID "$builder_gid"
  /usr/bin/dscl . -create "/Users/$builder_user" NFSHomeDirectory "$builder_home"
  /usr/bin/dscl . -create "/Users/$builder_user" UserShell /usr/bin/false
  /usr/bin/dscl . -create "/Users/$builder_user" IsHidden 1
else
  builder_uid="$(/usr/bin/id -u "$builder_user")"
  [[ "$builder_uid" -ge 501 && "$builder_uid" -lt 1000 ]] \
    || { echo "error: existing builder UID is outside the local service-account range" >&2; exit 77; }
  /usr/bin/dscl . -create "/Users/$builder_user" PrimaryGroupID "$builder_gid"
  [[ $(/usr/bin/dscl . -read "/Users/$builder_user" PrimaryGroupID \
      | /usr/bin/awk '{print $2}') == "$builder_gid" ]] \
    || { echo "error: builder primary group is not the dedicated group" >&2; exit 77; }
  [[ $(/usr/bin/dscl . -read "/Users/$builder_user" NFSHomeDirectory \
      | /usr/bin/awk '{print $2}') == "$builder_home" ]] \
    || { echo "error: existing builder home does not match the contract" >&2; exit 77; }
  [[ $(/usr/bin/dscl . -read "/Users/$builder_user" UserShell \
      | /usr/bin/awk '{print $2}') == /usr/bin/false ]] \
    || { echo "error: existing builder shell is interactive" >&2; exit 77; }
  [[ $(/usr/bin/dscl . -read "/Users/$builder_user" IsHidden \
      | /usr/bin/awk '{print $2}') == 1 ]] \
    || { echo "error: existing builder account is not hidden" >&2; exit 77; }
fi
if /usr/bin/dscl . -read "/Users/$builder_user" AuthenticationAuthority 2>/dev/null \
    | /usr/bin/grep -q '^AuthenticationAuthority:'; then
  echo "error: existing builder account has a password authentication authority" >&2
  exit 77
fi
# staff is deliberately absent here. macOS makes every local account a member
# through a well-known group GUID, so demanding non-membership is unsatisfiable;
# the interactive home's mode, not group membership, is what excludes the
# builder.
if /usr/sbin/dseditgroup -o checkmember -m "$builder_user" admin | /usr/bin/grep -q 'yes'; then
  echo "error: $builder_user unexpectedly belongs to admin" >&2
  exit 77
fi
/usr/bin/dscl . -create "/Users/$builder_user" Password '*'
/usr/sbin/createhomedir -c -u "$builder_user" >/dev/null
readonly builder_uid
/bin/launchctl print "user/$builder_uid" >/dev/null 2>&1 \
  || /bin/launchctl bootstrap "user/$builder_uid"
/bin/chmod 0700 "$builder_home"
/usr/sbin/chown "$builder_user":"$builder_group" "$builder_home"

# The source boundary is an allow list, and the interactive home's mode is what
# makes it one. macOS makes every local account a member of staff through a
# well-known group GUID, so a private home cannot rely on group membership. The
# authoritative checkout is therefore not in the home at all: it is state two
# accounts share, and shared state belongs to neither of them, exactly as the
# build store does. Its parent is root-owned and world-readable, which is what
# lets the builder resolve the checkout's own absolute path -- a directory the
# builder may traverse but not read cannot be named, and any tool calling
# getcwd() inside it fails.
#
# Keeping it outside the home removes the entire traverse-and-deny mechanism
# this provisioning used to need: no `allow search` on the developer's home, no
# per-sibling deny entry re-enumerated on every run to contain a traverse grant
# that reaches children by name, and no dependence on the home's mode. The
# builder reaches exactly one directory tree and nothing else.
[[ "$checkout" != "/Users/"* ]] \
  || { echo "error: authoritative checkout must not live in a user home" >&2; exit 78; }
/usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$checkout")"
[[ -d "$checkout" ]] \
  || { echo "error: authoritative checkout does not exist: $checkout" >&2; exit 72; }
[[ $(/usr/bin/stat -f '%Su' "$checkout") == "$developer_user" ]] \
  || { echo "error: authoritative checkout is not owned by $developer_user" >&2; exit 78; }
/bin/chmod 0755 "$checkout"
# Ownership denies the builder every write in the checkout, so only the
# world-writable objects package managers create need an explicit entry. The
# inheritable entry covers objects created later; the bounded scan covers the
# ones that predate it.
/bin/chmod +a \
  "$builder_user deny write,append,delete,writeattr,writeextattr,writesecurity,chown,file_inherit,directory_inherit" \
  "$checkout"
while IFS= read -r -d '' writable_path; do
  /bin/chmod -h +a \
    "$builder_user deny write,append,delete,writeattr,writeextattr,writesecurity,chown" \
    "$writable_path"
done < <(/usr/bin/find -x "$checkout" -perm -o+w -print0)

/usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$runner_root")"
/usr/bin/install -d -o "$builder_user" -g "$builder_group" -m 0755 "$runner_root"
/usr/bin/install -d -o "$builder_user" -g "$builder_group" -m 0755 "$runner_work_root"

if [[ -e "$runner_plist" || -L "$runner_plist" ]]; then
  echo "error: runner service state already exists" >&2
  exit 73
fi
if [[ "$runner_staging_state" == unregistered ]]; then
  /usr/bin/find -x "$runner_root" -mindepth 1 -delete
fi
/usr/bin/tar -xzf "$archive" -C "$runner_root"
/usr/sbin/chown -R "$builder_user":"$builder_group" "$runner_root"
run_as_builder "$runner_root/config.sh" \
  --unattended \
  --url "$organization" \
  --token "$registration_token" \
  --name "$runner_name" \
  --runnergroup "$runner_group" \
  --no-default-labels \
  --labels "$runner_label" \
  --work "$runner_work_root" \
  --disableupdate
registration_token=''
"$script_directory/finalize-nucleus-builder.sh"
