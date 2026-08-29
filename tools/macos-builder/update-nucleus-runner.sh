#!/bin/bash
# Installs the pinned Actions runner over an already-registered one.
#
# Provisioning is a first installation: it refuses to touch a host that already
# holds runner state, because registering a second time over a live runner is
# how a machine ends up with two identities. Retirement is the inverse and
# removes the account's machine-wide state wholesale. Neither is an upgrade, so
# a host that was already provisioned had no supported way to move between
# pinned versions at all, and the only paths available went through
# unregistering a working runner.
#
# An upgrade needs neither. The registration lives in dotfiles the release
# archive does not contain, so replacing everything the archive does provide
# leaves the runner registered as itself. What makes this safe to run rather
# than clever is that the previous installation is kept until the new one
# verifies, so a failure is a rename back rather than a re-registration.
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
source "$script_directory/runner-version.sh"

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}

readonly builder_user="$(contract_value builder.user)"
readonly builder_group="$(contract_value builder.group)"
readonly runner_root="$(contract_value builder.runnerRoot)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly runner_archive_url="$(contract_value builder.runnerArchiveURL)"
readonly expected_sha="$(contract_value builder.runnerArchiveSHA256)"
readonly expected_size="$(contract_value builder.runnerArchiveSize)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly boot_coordinator_service_label="$(contract_value builder.bootCoordinatorServiceLabel)"
readonly boot_coordinator_plist="/Library/LaunchDaemons/$boot_coordinator_service_label.plist"
readonly organization="$(contract_value builder.organization)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_label="$(contract_value builder.runnerLabel)"
readonly runner_work="$(contract_value builder.runnerWorkRoot)"
readonly quarantine_marker="$(contract_value builder.quarantineMarker)"

refuse_if_quarantined() {
  if [[ -e "$quarantine_marker" || -L "$quarantine_marker" ]]; then
    echo "error: nucleus-builder is quarantined; retire and recommission it instead of updating" >&2
    exit 77
  fi
}

# State the release archive does not carry. Registration is the reason an
# upgrade does not need a token, and the diagnostic history is the reason an
# upgrade does not erase the evidence of why it was wanted. `svc.sh` is written
# by registration rather than shipped, so it belongs here too; `runsvc.sh` is
# deliberately absent, because finalization copies it from the new `bin` and
# taking the old one forward is how a launcher outlives the runner it launches.
readonly preserved_entries=(
  .runner .credentials .credentials_rsaparams .env .path _diag svc.sh
)

registration_token=''
restore_boot_coordinator=false

cleanup() {
  registration_token=''
  if [[ "$restore_boot_coordinator" == true && -f "$boot_coordinator_plist" ]]; then
    /bin/launchctl print "system/$boot_coordinator_service_label" >/dev/null 2>&1 \
      || /bin/launchctl bootstrap system "$boot_coordinator_plist" >/dev/null 2>&1 \
      || true
  fi
}

stop_boot_coordinator() {
  restore_boot_coordinator=true
  /bin/launchctl bootout \
    "system/$boot_coordinator_service_label" >/dev/null 2>&1 || true
}

trap cleanup EXIT

usage() {
  cat >&2 <<'USAGE'
usage:
  update-nucleus-runner.sh --check [--offline]   report installed, pinned, and latest
  update-nucleus-runner.sh --fetch <directory>   download and verify the pinned archive
  sudo update-nucleus-runner.sh <archive>        install the pinned archive
  sudo update-nucleus-runner.sh --register       re-register this runner in place
                                                 (registration token on stdin)
USAGE
  exit 64
}

# Its local is not named `archive`: the installing path makes that name readonly
# before calling this, and a local that shadows a readonly global is refused
# outright rather than ignored.
verify_archive() {
  local candidate="$1" actual_sha actual_size
  [[ -f "$candidate" ]] || { echo "error: no such archive: $candidate" >&2; exit 66; }
  actual_sha="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')"
  actual_size="$(/usr/bin/stat -f '%z' "$candidate")"
  if [[ "$actual_sha" != "$expected_sha" || "$actual_size" != "$expected_size" ]]; then
    echo "error: archive does not match the pinned contract" >&2
    echo "  expected sha256 $expected_sha size $expected_size" >&2
    echo "  actual   sha256 $actual_sha size $actual_size" >&2
    exit 65
  fi
}

# A job executing now would lose its containers and its work when the service
# stops. The guard is here rather than after the stop, because a check that runs
# after the destructive step reports a condition it has already violated.
refuse_while_busy() {
  if /bin/ps -axo command= \
      | /usr/bin/awk -v worker="$runner_root/bin/Runner.Worker" \
        '$1 == worker { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "error: a job is executing on this runner" >&2
    exit 75
  fi
  if /usr/bin/pgrep -qf 'collider-cli/release/collider' 2>/dev/null; then
    echo "error: a Collider run is executing on this host" >&2
    exit 75
  fi
}

case "${1:-}" in
--check)
  [[ $# -le 2 ]] || usage
  installed="$(nucleus_installed_runner_version "$runner_root" || true)"
  printf 'installed %s\n' "${installed:-unknown}"
  printf 'pinned    %s\n' "$runner_version"
  status=0
  if [[ "${installed:-}" != "$runner_version" ]]; then
    echo "this host is behind the pinned contract; install it here" >&2
    status=1
  fi
  if [[ "${2:-}" != --offline ]]; then
    latest="$(nucleus_latest_runner_version || true)"
    printf 'latest    %s\n' "${latest:-unknown}"
    if [[ -n "${latest:-}" && "$latest" != "$runner_version" ]]; then
      echo "the pinned contract is behind upstream; bump it in the repository" >&2
      status=$((status | 2))
    fi
  fi
  exit "$status"
  ;;
--fetch)
  [[ $# -eq 2 ]] || usage
  destination="$2"
  [[ -d "$destination" ]] || { echo "error: no such directory: $destination" >&2; exit 66; }
  archive="$destination/${runner_archive_url##*/}"
  if [[ ! -f "$archive" ]]; then
    /usr/bin/curl --fail --location --show-error --output "$archive" "$runner_archive_url"
  fi
  verify_archive "$archive"
  printf '%s\n' "$archive"
  exit 0
  ;;
--register)
  # Registration lives only on this host, so losing it leaves binaries that
  # cannot authenticate and a server-side runner that will never come back
  # online. Provisioning cannot repair that: it is a first installation and
  # refuses a host that already carries service state. Registering in place
  # replaces the server's record of this runner with a new credential for the
  # same identity, which is what `--replace` means, and changes nothing else.
  [[ $EUID -eq 0 && $# -eq 1 ]] || usage
  refuse_if_quarantined
  IFS= read -r registration_token
  [[ -n "$registration_token" ]] \
    || { echo "error: a short-lived registration token is required on stdin" >&2; exit 64; }
  [[ -x "$runner_root/config.sh" ]] \
    || { echo "error: no runner is installed at $runner_root" >&2; exit 73; }
  refuse_while_busy
  builder_uid="$(/usr/bin/id -u "$builder_user")"
  stop_boot_coordinator
  /bin/launchctl bootout "user/$builder_uid/$runner_service_label" >/dev/null 2>&1 || true
  # Configuration writes its credentials into the runner root, which
  # finalization leaves owned by root.
  /usr/sbin/chown -R "$builder_user":"$builder_group" "$runner_root"
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
    "$runner_root/config.sh" \
    --unattended \
    --replace \
    --url "$organization" \
    --token "$registration_token" \
    --name "$runner_name" \
    --runnergroup "$runner_group" \
    --no-default-labels \
    --labels "$runner_label" \
    --work "$runner_work" \
    --disableupdate
  registration_token=''
  "$script_directory/finalize-nucleus-builder.sh"
  exit 0
  ;;
-h | --help)
  usage
  ;;
esac

[[ $EUID -eq 0 && $# -eq 1 ]] || usage
refuse_if_quarantined
readonly archive="$1"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly service_target="user/$builder_uid/$runner_service_label"
readonly incoming="$runner_root.incoming"
readonly previous="$runner_root.previous"

verify_archive "$archive"
[[ -d "$runner_root" && ! -L "$runner_root" ]] \
  || { echo "error: runner root is not a directory: $runner_root" >&2; exit 73; }
[[ -f "$runner_root/.runner" ]] \
  || { echo "error: runner is not registered; provision it instead" >&2; exit 73; }
if [[ "$(nucleus_installed_runner_version "$runner_root" || true)" == "$runner_version" ]]; then
  echo "runner $runner_version is already installed"
  exit 0
fi
[[ ! -e "$incoming" && ! -e "$previous" ]] \
  || { echo "error: a previous update left $incoming or $previous behind" >&2; exit 73; }
refuse_while_busy

stop_boot_coordinator
/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
for _ in {1..50}; do
  /bin/launchctl print "$service_target" >/dev/null 2>&1 || break
  /bin/sleep 0.2
done
! /bin/launchctl print "$service_target" >/dev/null 2>&1 \
  || { echo "error: runner service did not stop" >&2; exit 75; }

/usr/bin/install -d -o "$builder_user" -g "$builder_group" -m 0755 "$incoming"
/usr/bin/tar -xzf "$archive" -C "$incoming"
# Copied rather than moved. Moving leaves the retained installation missing the
# very files that make it a runner, so the rollback below would restore a tree
# that cannot authenticate and would destroy the only copy on its way there.
# Keeping both complete is what makes the rollback a rollback.
for entry in "${preserved_entries[@]}"; do
  [[ -e "$runner_root/$entry" ]] || continue
  /bin/cp -pR "$runner_root/$entry" "$incoming/$entry"
done
for entry in "${preserved_entries[@]}"; do
  [[ -e "$runner_root/$entry" ]] || continue
  [[ -e "$incoming/$entry" ]] \
    || { echo "error: $entry did not reach the staged runner" >&2; exit 70; }
done
/bin/mv "$runner_root" "$previous"
/bin/mv "$incoming" "$runner_root"
/usr/sbin/chown -R "$builder_user":"$builder_group" "$runner_root"

# Finalization owns the service descriptor, the runsvc copy, the watchdog, and
# the ownership this host asserts, and it ends by verifying all of it including
# that the installed version is now the pinned one. Rolling back on its failure
# is why the previous installation is still here.
if ! "$script_directory/finalize-nucleus-builder.sh"; then
  echo "error: finalization failed; restoring the previous runner" >&2
  # The retained installation is complete because the state above was copied,
  # so this is a swap back rather than a reconstruction. Refuse to discard the
  # staged tree until that is true, since the alternative is destroying a
  # registration that only exists here.
  for entry in "${preserved_entries[@]}"; do
    [[ -e "$runner_root/$entry" ]] || continue
    [[ -e "$previous/$entry" ]] && continue
    echo "error: $previous lacks $entry; refusing to discard $runner_root" >&2
    echo "error: the runner is at $runner_root and the previous tree at $previous" >&2
    exit 70
  done
  /bin/rm -rf "$runner_root"
  /bin/mv "$previous" "$runner_root"
  "$script_directory/finalize-nucleus-builder.sh" || true
  exit 70
fi
/bin/rm -rf "$previous"
echo "installed runner $runner_version"
