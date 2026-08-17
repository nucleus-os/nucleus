#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly starter_source="$script_directory/container-system-start"
readonly plist_template="$script_directory/com.nucleus.container-system-start.plist.in"
readonly service_label="$(
  /usr/bin/plutil -extract launchd.label raw -o - "$contract"
)"

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
readonly application_support_root="$service_home/Library/Application Support/Nucleus/Collider"
readonly service_support_root="$application_support_root/service"
readonly starter_target="$service_support_root/container-system-start"
readonly developer_root="$service_home/Library/Developer/Nucleus/Collider"
readonly app_root="$developer_root/apple-container"
readonly cache_root="$service_home/Library/Caches/Nucleus/Collider"
readonly logs_root="$service_home/Library/Logs/Nucleus/Collider"
readonly service_logs="$logs_root/service"
readonly standard_output_path="$service_logs/apple-container-apiserver.log"
readonly standard_error_path="$service_logs/apple-container-apiserver.error.log"
readonly agent_directory="$service_home/Library/LaunchAgents"
readonly agent_target="$agent_directory/$service_label.plist"

if [[ ! -d "$service_home" ]]; then
  echo "error: current-user home is absent: $service_home" >&2
  exit 72
fi
if /bin/launchctl print "gui/$service_uid" >/dev/null 2>&1; then
  readonly service_domain="gui/$service_uid"
elif /bin/launchctl print "user/$service_uid" >/dev/null 2>&1; then
  readonly service_domain="user/$service_uid"
else
  echo "error: no per-user launchd domain exists for $service_user" >&2
  echo "error: root provisioning must bootstrap user/$service_uid first" >&2
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
  "$application_support_root" \
  "$service_support_root" \
  "$developer_root" \
  "$app_root" \
  "$developer_root/build" \
  "$developer_root/artifacts" \
  "$cache_root" \
  "$cache_root/downloads" \
  "$cache_root/native-sdks" \
  "$cache_root/android-sdks" \
  "$logs_root" \
  "$logs_root/runs" \
  "$service_logs" \
  "$agent_directory"
do
  /usr/bin/install -d -m 0755 "$required_path"
  if [[ $(/usr/bin/stat -f '%u' "$required_path") -ne $service_uid ]]; then
    echo "error: $required_path is not owned by $service_user" >&2
    exit 77
  fi
done

# Persistent container disks and incremental build workspaces are deliberately
# reconstructible. Keep this large developer-data root out of Time Machine
# without requiring a privileged fixed-path or volume exclusion.
/usr/bin/tmutil addexclusion "$developer_root"

# The starter exits after Apple Container launches its detached user services.
# Booting out the LaunchAgent alone therefore does not restart the API server or
# reload its persisted image and volume metadata.
/bin/launchctl bootout "$service_domain/$service_label" >/dev/null 2>&1 || true
if /usr/local/bin/container system status --format json >/dev/null 2>&1; then
  /usr/local/bin/container system stop
fi
/usr/bin/install -m 0755 "$starter_source" "$starter_target"
/usr/bin/install -m 0644 "$plist_template" "$agent_target"
/usr/bin/plutil -remove ProgramArguments "$agent_target"
/usr/bin/plutil -insert ProgramArguments -array "$agent_target"
/usr/bin/plutil -insert ProgramArguments.0 -string "$starter_target" "$agent_target"
/usr/bin/plutil -replace StandardOutPath -string "$standard_output_path" \
  "$agent_target"
/usr/bin/plutil -replace StandardErrorPath -string "$standard_error_path" \
  "$agent_target"
/usr/bin/plutil -lint "$agent_target" >/dev/null

/bin/launchctl bootstrap "$service_domain" "$agent_target"
/bin/launchctl kickstart -k "$service_domain/$service_label"

echo "waiting for the per-user Apple container API server..."
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

echo "error: Apple container did not become healthy in $service_domain" >&2
/bin/launchctl print "$service_domain/$service_label" >&2 || true
echo "--- $standard_error_path ---" >&2
/usr/bin/tail -100 "$standard_error_path" >&2 \
  || true
exit 70
