#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly installer="$script_directory/install-container-service.sh"
readonly service_label="$(
  /usr/bin/plutil -extract launchd.label raw -o - "$contract"
)"
readonly app_root="$(
  /usr/bin/plutil -extract appleContainer.appRoot raw -o - "$contract"
)"
readonly volume_root="$(
  /usr/bin/plutil -extract appleContainer.volumeRoot raw -o - "$contract"
)"
readonly source_root="$app_root/volumes"
readonly backup_root="$app_root/volumes.pre-build-storage-migration"
readonly service_uid="$(/usr/bin/id -u)"

if [[ $EUID -eq 0 ]]; then
  echo "error: run this migration as the logged-in builder user, without sudo" >&2
  exit 77
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 64
fi
if [[ "$app_root" != /Volumes/NucleusOCI/* \
    || "$volume_root" != /Volumes/NucleusBuild/* ]]; then
  echo "error: refusing storage paths outside the declared Nucleus volumes" >&2
  exit 69
fi
if [[ -L "$source_root" ]]; then
  if [[ "$(/usr/bin/readlink "$source_root")" != "$volume_root" ]]; then
    echo "error: $source_root points at an unexpected destination" >&2
    exit 78
  fi
  exec "$installer"
fi
if [[ ! -d "$source_root" ]]; then
  echo "error: Apple container source volume root is absent: $source_root" >&2
  exit 72
fi
if [[ -e "$backup_root" ]]; then
  echo "error: prior migration backup requires inspection: $backup_root" >&2
  exit 78
fi
if /usr/local/bin/container system status --format json >/dev/null 2>&1; then
  if [[ -n "$(/usr/local/bin/container list --quiet)" ]]; then
    echo "error: stop all running build containers before migrating storage" >&2
    exit 75
  fi
fi

echo "stopping the login-session Apple container service..."
/bin/launchctl bootout "gui/$service_uid/$service_label" >/dev/null 2>&1 || true
/usr/local/bin/container system stop >/dev/null 2>&1 || true

echo "copying Apple container volumes into NucleusBuild..."
/usr/bin/install -d -m 0755 "$volume_root"
if [[ -z "$(/usr/bin/find "$volume_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  /bin/cp -ac "$source_root/." "$volume_root/"
fi

readonly comparison="$(
  /usr/bin/rsync -ani --delete "$source_root/" "$volume_root/"
)"
if [[ -n "$comparison" ]]; then
  echo "error: copied volume root did not verify cleanly" >&2
  echo "$comparison" >&2
  exit 74
fi

/bin/mv "$source_root" "$backup_root"
/bin/ln -s "$volume_root" "$source_root"

if ! "$installer"; then
  echo "error: migrated service failed to start; restoring the original volume root" >&2
  /bin/launchctl bootout "gui/$service_uid/$service_label" >/dev/null 2>&1 || true
  /usr/local/bin/container system stop >/dev/null 2>&1 || true
  /bin/rm "$source_root"
  /bin/mv "$backup_root" "$source_root"
  "$installer" || true
  exit 70
fi

/bin/rm -rf "$backup_root"
echo "migrated Apple container volumes to $volume_root"
