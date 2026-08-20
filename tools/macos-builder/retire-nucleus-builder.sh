#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly machine_root_library="$script_directory/builder-machine-root.sh"

if [[ $EUID -ne 0 || $# -ne 0 ]]; then
  echo "usage: sudo $0" >&2
  exit 64
fi

source "$machine_root_library"

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}

readonly builder_user="$(contract_value builder.user)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly declared_runner_root="$(contract_value builder.runnerRoot)"
readonly host_contract_root="$(contract_value builder.hostContractRoot)"
readonly runner_plist="$host_contract_root/$runner_service_label.plist"
readonly legacy_runner_agent_plist="/Library/LaunchAgents/$runner_service_label.plist"
readonly legacy_runner_plist="/Library/LaunchDaemons/$runner_service_label.plist"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly developer_uid="$(/usr/bin/id -u "$developer_user")"
readonly runner_service_domain="user/$builder_uid"

if /bin/ps -axo command= \
    | /usr/bin/awk -v worker="$declared_runner_root/bin/Runner.Worker" \
      '$1 == worker { found = 1 } END { exit(found ? 0 : 1) }'; then
  echo "error: a job is executing on this runner; drain it before retiring" >&2
  exit 75
fi

# The installed service records what is actually installed, which may predate
# the machine roots the current contract declares.
installed_machine_root=""
for installed_plist in "$runner_plist" "$legacy_runner_agent_plist" "$legacy_runner_plist"; do
  if [[ -f "$installed_plist" && ! -L "$installed_plist" ]]; then
    installed_service="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$installed_plist")"
    installed_machine_root="$(/usr/bin/dirname "$(/usr/bin/dirname "$installed_service")")"
    break
  fi
done

for service_domain in \
  "$runner_service_domain" \
  "gui/$builder_uid" \
  "user/$developer_uid" \
  "gui/$developer_uid" \
  user/0 \
  gui/0 \
  system
do
  if ! /bin/launchctl print "$service_domain/$runner_service_label" >/dev/null 2>&1; then
    continue
  fi
  /bin/launchctl bootout "$service_domain/$runner_service_label" || true
  for _ in {1..50}; do
    /bin/launchctl print "$service_domain/$runner_service_label" >/dev/null 2>&1 || break
    /bin/sleep 0.2
  done
  ! /bin/launchctl print "$service_domain/$runner_service_label" >/dev/null 2>&1 \
    || { echo "error: runner service is still loaded in $service_domain" >&2; exit 70; }
done
/bin/rm -f \
  "$runner_plist" \
  "$legacy_runner_agent_plist" \
  "$legacy_runner_plist" \
  /etc/sudoers.d/nucleus-builder \
  /usr/local/bin/collider \
  /usr/local/bin/nucleus-builder-run

for machine_root in \
  "$installed_machine_root" \
  "$(/usr/bin/dirname "$declared_runner_root")"
do
  [[ -n "$machine_root" ]] || continue
  [[ -e "$machine_root" || -L "$machine_root" ]] || continue
  nucleus_supported_machine_root_path "$machine_root" \
    && nucleus_machine_root_holds_only_builder_state "$machine_root" \
    || { echo "error: refusing to remove unrecognized machine root: $machine_root" >&2; exit 73; }
  /bin/rm -rf "$machine_root"
done

echo "retired the runner service, machine-wide builder state, and installed launchers"
echo "preserved $builder_user, its source ACLs, per-user Collider storage, and container service"
