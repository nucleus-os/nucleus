#!/bin/bash
# Stops the trusted builder and leaves a persistent fail-closed marker.
#
# Quarantine is not a pause switch. It is used after suspected compromise,
# unexpected persistence, an account-boundary failure, or cache-integrity
# failure. The marker survives reboot and has no in-place clearing command:
# recovery retires and recommissions the reconstructible builder state.
set -euo pipefail

if [[ $EUID -ne 0 || $# -ne 0 ]]; then
  echo "usage: sudo $0" >&2
  exit 64
fi

readonly builder_user="nucleus-builder"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly host_contract_root="/Library/Nucleus/Builder"
readonly quarantine_marker="$host_contract_root/quarantined"
readonly runner_service_label="com.nucleus.github-actions-runner"
readonly runner_watchdog_service_label="com.nucleus.github-actions-runner-watchdog"
readonly container_service_label="com.nucleus.container-system-start"
readonly service_domain="user/$builder_uid"

[[ "$quarantine_marker" == "$host_contract_root"/* ]] \
  || { echo "error: quarantine marker is outside the host contract root" >&2; exit 78; }
[[ -d "$host_contract_root" && ! -L "$host_contract_root" ]] \
  || { echo "error: host contract root is absent" >&2; exit 72; }
[[ ! -L "$quarantine_marker" ]] \
  || { echo "error: quarantine marker is a symbolic link" >&2; exit 73; }

temporary_marker="$(/usr/bin/mktemp "$host_contract_root/.quarantined.XXXXXX")"
trap '/bin/rm -f "$temporary_marker"' EXIT
printf '%s\n' "quarantined $(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$temporary_marker"
/usr/sbin/chown root:wheel "$temporary_marker"
/bin/chmod 0644 "$temporary_marker"
/bin/mv -f "$temporary_marker" "$quarantine_marker"

# The marker lands before any process is stopped, so the periodic coordinator
# cannot race the shutdown and expose a new listener. Stop the entry services,
# then terminate every process owned by the identity whose state is now
# untrusted. The root quarantine process is outside that identity and survives.
for label in \
  "$runner_watchdog_service_label" \
  "$runner_service_label" \
  "$container_service_label"; do
  /bin/launchctl bootout "$service_domain/$label" >/dev/null 2>&1 || true
done
/usr/bin/pkill -TERM -u "$builder_uid" >/dev/null 2>&1 || true
for _ in {1..50}; do
  /usr/bin/pgrep -u "$builder_uid" >/dev/null 2>&1 || break
  /bin/sleep 0.1
done
/usr/bin/pkill -KILL -u "$builder_uid" >/dev/null 2>&1 || true

echo "quarantined $builder_user; retire and recommission the builder before trusted execution"
