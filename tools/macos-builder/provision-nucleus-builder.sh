#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly acl_library="$script_directory/builder-acl.sh"

source "$acl_library"

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
run_as_builder() {
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" "$@"
}

readonly archive="$1"
readonly builder_user="$(contract_value builder.user)"
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
readonly runner_root="/Library/Application Support/Nucleus/GitHubActionsRunner"
readonly host_contract_root="/Library/Application Support/Nucleus/Builder"
readonly runner_plist="/Library/LaunchDaemons/$runner_service_label.plist"

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
  [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_root") == "$builder_user:staff:755" ]] \
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

if ! /usr/bin/dscl . -read "/Users/$builder_user" >/dev/null 2>&1; then
  maximum_uid="$(/usr/bin/dscl . -list /Users UniqueID \
    | /usr/bin/awk '$2 >= 501 && $2 < 1000 {print $2}' \
    | /usr/bin/sort -n | /usr/bin/tail -1)"
  builder_uid="$(( ${maximum_uid:-500} + 1 ))"
  /usr/bin/dscl . -create "/Users/$builder_user"
  /usr/bin/dscl . -create "/Users/$builder_user" RealName "Nucleus Builder"
  /usr/bin/dscl . -create "/Users/$builder_user" UniqueID "$builder_uid"
  /usr/bin/dscl . -create "/Users/$builder_user" PrimaryGroupID 20
  /usr/bin/dscl . -create "/Users/$builder_user" NFSHomeDirectory "$builder_home"
  /usr/bin/dscl . -create "/Users/$builder_user" UserShell /usr/bin/false
  /usr/bin/dscl . -create "/Users/$builder_user" IsHidden 1
else
  builder_uid="$(/usr/bin/id -u "$builder_user")"
  [[ "$builder_uid" -ge 501 && "$builder_uid" -lt 1000 ]] \
    || { echo "error: existing builder UID is outside the local service-account range" >&2; exit 77; }
  [[ $(/usr/bin/dscl . -read "/Users/$builder_user" PrimaryGroupID \
      | /usr/bin/awk '{print $2}') == 20 ]] \
    || { echo "error: existing builder primary group is not staff" >&2; exit 77; }
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
/usr/sbin/chown "$builder_user":staff "$builder_home"

if [[ "$runner_staging_state" == fresh ]]; then
  # These ACLs expose only the named source path. POSIX mode and an explicit
  # deny retain a read-only boundary even though both accounts use staff.
  /bin/chmod +a "$builder_user allow search" "/Users/$developer_user"
  /bin/chmod +a "$builder_user allow search" "/Users/$developer_user/Developer"
  nucleus_apply_acl_tree \
    "$checkout" \
    "$builder_user allow read,execute" \
    "$builder_user allow read,execute,file_inherit,directory_inherit"
  nucleus_apply_acl_tree \
    "$checkout" \
    "$builder_user deny write,append,delete,writeattr,writeextattr,writesecurity,chown" \
    "$builder_user deny add_file,add_subdirectory,delete_child,delete,writeattr,writeextattr,writesecurity,chown,file_inherit,directory_inherit"
  while IFS= read -r -d '' unrelated_path; do
    /bin/chmod +a "$builder_user deny read,write,execute,delete" "$unrelated_path"
  done < <(/usr/bin/find "/Users/$developer_user" -mindepth 1 -maxdepth 1 \
    ! -name Developer -print0)
  while IFS= read -r -d '' unrelated_path; do
    /bin/chmod +a "$builder_user deny read,write,execute,delete" "$unrelated_path"
  done < <(/usr/bin/find "/Users/$developer_user/Developer" -mindepth 1 -maxdepth 1 \
    ! -path "$checkout" -print0)
fi

/usr/bin/install -d -o root -g wheel -m 0755 "/Library/Application Support/Nucleus"
/usr/bin/install -d -o "$builder_user" -g staff -m 0755 "$runner_root"

if [[ -e "$runner_plist" || -L "$runner_plist" ]]; then
  echo "error: runner service state already exists" >&2
  exit 73
fi
if [[ "$runner_staging_state" == unregistered ]]; then
  /usr/bin/find -x "$runner_root" -mindepth 1 -delete
fi
/usr/bin/tar -xzf "$archive" -C "$runner_root"
/usr/sbin/chown -R "$builder_user":staff "$runner_root"
run_as_builder "$runner_root/config.sh" \
  --unattended \
  --url "$organization" \
  --token "$registration_token" \
  --name "$runner_name" \
  --runnergroup "$runner_group" \
  --no-default-labels \
  --labels "$runner_label" \
  --work _work \
  --disableupdate
registration_token=''
"$script_directory/finalize-nucleus-builder.sh"
