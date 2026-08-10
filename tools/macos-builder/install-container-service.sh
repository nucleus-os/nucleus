#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly starter_source="$script_directory/container-system-start"
readonly plist_template="$script_directory/com.nucleus.container-system-start.plist.in"
readonly service_label="com.nucleus.container-system-start"

if [[ $EUID -eq 0 ]]; then
  echo "error: run this installer as the logged-in builder user, without sudo" >&2
  exit 77
fi

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 64
fi

readonly service_user="$(/usr/bin/id -un)"
readonly service_uid="$(/usr/bin/id -u)"
readonly service_home="$(
  /usr/bin/dscl . -read "/Users/$service_user" NFSHomeDirectory \
    | /usr/bin/sed 's/^NFSHomeDirectory: //'
)"
readonly starter_relative_path="$(
  /usr/bin/plutil -extract launchd.starterRelativePath raw -o - "$contract"
)"
if [[ -z "$starter_relative_path" || "$starter_relative_path" == /* \
    || "/$starter_relative_path/" == *"/../"* ]]; then
  echo "error: launchd starter path must be relative to the current user's home" >&2
  exit 69
fi
readonly starter_target="$service_home/$starter_relative_path"
readonly starter_directory="$(/usr/bin/dirname "$starter_target")"
readonly agent_directory="$service_home/Library/LaunchAgents"
readonly agent_target="$agent_directory/$service_label.plist"

if [[ ! -d "$service_home" ]]; then
  echo "error: current-user home is absent: $service_home" >&2
  exit 72
fi
if ! /bin/launchctl print "gui/$service_uid" >/dev/null 2>&1; then
  echo "error: $service_user must have an active login session" >&2
  exit 69
fi

readonly expected_container_version="$(
  /usr/bin/plutil -extract appleContainer.version raw -o - "$contract"
)"
readonly expected_maximum_open_file_count="$(
  /usr/bin/plutil -extract launchd.maximumOpenFileCount raw -o - "$contract"
)"
readonly template_soft_open_file_count="$(
  /usr/bin/plutil -extract SoftResourceLimits.NumberOfFiles raw -o - \
    "$plist_template"
)"
readonly template_hard_open_file_count="$(
  /usr/bin/plutil -extract HardResourceLimits.NumberOfFiles raw -o - \
    "$plist_template"
)"
readonly host_maximum_open_file_count="$(
  /usr/sbin/sysctl -n kern.maxfilesperproc
)"
if [[ "$template_soft_open_file_count" != "$expected_maximum_open_file_count" \
    || "$template_hard_open_file_count" != "$expected_maximum_open_file_count" ]]; then
  echo "error: container service plist descriptor limits do not match the host contract" >&2
  exit 69
fi
if (( host_maximum_open_file_count < expected_maximum_open_file_count )); then
  echo "error: kern.maxfilesperproc is $host_maximum_open_file_count; expected at least $expected_maximum_open_file_count" >&2
  exit 69
fi
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

/bin/launchctl bootout "gui/$service_uid/$service_label" >/dev/null 2>&1 || true
/usr/bin/install -d -m 0755 "$starter_directory"
/usr/bin/install -m 0755 "$starter_source" "$starter_target"
/usr/bin/install -d -m 0755 "$agent_directory"
/usr/bin/install -m 0644 "$plist_template" "$agent_target"
/usr/bin/plutil -remove ProgramArguments.0 "$agent_target"
/usr/bin/plutil -insert ProgramArguments.0 -string "$starter_target" \
  "$agent_target"
/usr/bin/plutil -lint "$agent_target" >/dev/null

/bin/launchctl bootstrap "gui/$service_uid" "$agent_target"
/bin/launchctl kickstart -k "gui/$service_uid/$service_label"

echo "waiting for the login-session Apple container API server..."
for attempt in {1..60}; do
  if /usr/local/bin/container system status --format json >/dev/null 2>&1; then
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
