#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly starter_source="$script_directory/container-system-start"
readonly plist_template="$script_directory/com.nucleus.container-system-start.plist.in"
readonly starter_target="/usr/local/libexec/nucleus/container-system-start"
readonly service_label="com.nucleus.container-system-start"
readonly legacy_system_labels=(
  "$service_label"
  "com.apple.container.container-network-vmnet.default"
  "com.apple.container.container-network-vmnet.nucleus-build-internal"
  "com.apple.container.container-core-images"
  "com.apple.container.machine-apiserver"
)

if [[ $EUID -ne 0 ]]; then
  echo "usage: sudo $0 <service-user>" >&2
  exit 77
fi

if [[ $# -ne 1 ]]; then
  echo "usage: sudo $0 <service-user>" >&2
  exit 64
fi

readonly service_user="$1"
if [[ ! "$service_user" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "error: invalid service user: $service_user" >&2
  exit 64
fi
if ! /usr/bin/id "$service_user" >/dev/null 2>&1; then
  echo "error: service user does not exist: $service_user" >&2
  exit 67
fi
readonly service_group="$(/usr/bin/id -gn "$service_user")"
readonly service_uid="$(/usr/bin/id -u "$service_user")"
readonly service_home="$(
  /usr/bin/dscl . -read "/Users/$service_user" NFSHomeDirectory \
    | /usr/bin/awk '{ print $2 }'
)"
readonly agent_directory="$service_home/Library/LaunchAgents"
readonly agent_target="$agent_directory/$service_label.plist"

if [[ ! -d "$service_home" ]]; then
  echo "error: service-user home is absent: $service_home" >&2
  exit 72
fi
if ! /bin/launchctl print "gui/$service_uid" >/dev/null 2>&1; then
  echo "error: $service_user must be logged in while provisioning the launch agent" >&2
  exit 69
fi

readonly expected_container_version="$(
  /usr/bin/plutil -extract appleContainer.version raw -o - "$contract"
)"
readonly installed_container_version="$(
  /usr/local/bin/container --version \
    | /usr/bin/sed -E 's/^container CLI version ([^ ]+).*/\1/'
)"
if [[ "$installed_container_version" != "$expected_container_version" ]]; then
  echo "error: Apple container $expected_container_version is required; found $installed_container_version" >&2
  exit 69
fi

for required_path in \
  /Volumes/NucleusOCI/apple-container \
  /Volumes/NucleusLogs
do
  if [[ ! -d "$required_path" ]]; then
    echo "error: required macOS builder path is absent: $required_path" >&2
    exit 72
  fi
  if [[ $(/usr/bin/stat -f '%u' "$required_path") -ne $service_uid ]]; then
    echo "error: $required_path is not owned by $service_user" >&2
    exit 77
  fi
done

echo "removing the unsupported system-domain Apple container services..."
for legacy_label in "${legacy_system_labels[@]}"; do
  /bin/launchctl bootout "system/$legacy_label" >/dev/null 2>&1 || true
  /bin/rm -f "/Library/LaunchDaemons/$legacy_label.plist"
done

/bin/launchctl bootout "gui/$service_uid/$service_label" >/dev/null 2>&1 || true
/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec/nucleus
/usr/bin/install -o root -g wheel -m 0755 "$starter_source" "$starter_target"
/usr/bin/install -d -o "$service_user" -g "$service_group" -m 0755 "$agent_directory"
/usr/bin/install -o "$service_user" -g "$service_group" -m 0644 \
  "$plist_template" "$agent_target"
/usr/bin/plutil -lint "$agent_target" >/dev/null

/bin/launchctl bootstrap "gui/$service_uid" "$agent_target"
/bin/launchctl kickstart -k "gui/$service_uid/$service_label"

echo "waiting for the login-session Apple container API server..."
for attempt in {1..60}; do
  if /bin/launchctl asuser "$service_uid" /usr/bin/sudo -u "$service_user" \
      /usr/local/bin/container system status --format json >/dev/null 2>&1; then
    echo "installed persistent Apple container launch agent for $service_user"
    exit 0
  fi
  if (( attempt % 5 == 0 )); then
    echo "  still waiting ($attempt/60)"
  fi
  /bin/sleep 1
done

echo "error: Apple container did not become healthy in the login session" >&2
/bin/launchctl print "gui/$service_uid/$service_label" >&2 || true
echo "--- /Volumes/NucleusLogs/apple-container-apiserver.error.log ---" >&2
/usr/bin/tail -100 /Volumes/NucleusLogs/apple-container-apiserver.error.log >&2 \
  || true
exit 70
