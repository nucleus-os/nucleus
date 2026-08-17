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
run_as_builder() {
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" "$@"
}

readonly archive="$1"
readonly builder_user="$(contract_value builder.user)"
readonly builder_home="$(contract_value builder.home)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly repository="$(contract_value builder.repository)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_label="$(contract_value builder.runnerLabel)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly expected_sha="$(contract_value builder.runnerArchiveSHA256)"
readonly expected_size="$(contract_value builder.runnerArchiveSize)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly runner_root="/Library/Application Support/Nucleus/GitHubActionsRunner"
readonly runner_work="$runner_root/_work"
readonly runner_logs="$builder_home/Library/Logs/Nucleus/GitHubActionsRunner"
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
  /usr/bin/dscl . -passwd "/Users/$builder_user" '*'
  /usr/sbin/createhomedir -c -u "$builder_user" >/dev/null
else
  builder_uid="$(/usr/bin/id -u "$builder_user")"
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
readonly builder_uid
/bin/launchctl print "user/$builder_uid" >/dev/null 2>&1 \
  || /bin/launchctl bootstrap "user/$builder_uid"

if /usr/sbin/dseditgroup -o checkmember -m "$builder_user" admin | /usr/bin/grep -q 'yes'; then
  echo "error: $builder_user unexpectedly belongs to admin" >&2
  exit 77
fi
/bin/chmod 0700 "$builder_home"
/usr/sbin/chown "$builder_user":staff "$builder_home"

# These ACLs expose only the named source path. POSIX mode and an explicit deny
# retain a read-only boundary even though both accounts use the staff group.
/bin/chmod +a "$builder_user allow search" "/Users/$developer_user"
/bin/chmod +a "$builder_user allow search" "/Users/$developer_user/Developer"
/bin/chmod -R +a "$builder_user allow read,execute" "$checkout"
/bin/chmod -R +a "$builder_user deny write,delete,writeattr,writeextattr,writesecurity,chown" "$checkout"
while IFS= read -r -d '' unrelated_path; do
  /bin/chmod +a "$builder_user deny read,write,execute,delete" "$unrelated_path"
done < <(/usr/bin/find "/Users/$developer_user" -mindepth 1 -maxdepth 1 \
  ! -name Developer -print0)
while IFS= read -r -d '' unrelated_path; do
  /bin/chmod +a "$builder_user deny read,write,execute,delete" "$unrelated_path"
done < <(/usr/bin/find "/Users/$developer_user/Developer" -mindepth 1 -maxdepth 1 \
  ! -path "$checkout" -print0)

for path in \
  "$runner_logs" \
  "$builder_home/Library/Application Support/Nucleus/Collider" \
  "$builder_home/Library/Developer/Nucleus/Collider" \
  "$builder_home/Library/Caches/Nucleus/Collider" \
  "$builder_home/Library/Logs/Nucleus/Collider"
do
  /usr/bin/install -d -o "$builder_user" -g staff -m 0755 "$path"
done
/usr/bin/install -d -o root -g wheel -m 0755 "/Library/Application Support/Nucleus"
/usr/bin/install -d -o "$builder_user" -g staff -m 0755 "$runner_root"

if [[ -e "$runner_plist" ]] \
    || [[ -n "$(/usr/bin/find "$runner_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "error: runner state already exists; provisioning never replaces it" >&2
  exit 73
fi
/usr/bin/tar -xzf "$archive" -C "$runner_root"
/usr/sbin/chown -R "$builder_user":staff "$runner_root"
run_as_builder "$runner_root/config.sh" \
  --unattended \
  --url "$repository" \
  --token "$registration_token" \
  --name "$runner_name" \
  --runnergroup "$runner_group" \
  --no-default-labels \
  --labels "$runner_label" \
  --work _work \
  --disableupdate
registration_token=''
/bin/cp "$runner_root/bin/runsvc.sh" "$runner_root/runsvc.sh"
/bin/chmod 0755 "$runner_root/runsvc.sh"
/usr/sbin/chown -R root:wheel "$runner_root"
/usr/sbin/chown -R "$builder_user":staff "$runner_root/_diag" "$runner_work"
/bin/chmod 0755 "$runner_root/_diag" "$runner_work"
for credential in .credentials .credentials_rsaparams .runner; do
  /usr/sbin/chown root:staff "$runner_root/$credential"
  /bin/chmod 0640 "$runner_root/$credential"
done

/usr/bin/install -d -o root -g wheel -m 0755 "$host_contract_root"
if [[ -e "$host_contract_root/authoritative-checkout" ]] \
    && [[ $(/usr/bin/sed -n '1p' "$host_contract_root/authoritative-checkout") != "$checkout" ]]; then
  echo "error: installed authoritative checkout contract differs" >&2
  exit 73
fi
printf '%s\n' "$checkout" >"$host_contract_root/authoritative-checkout"
/usr/sbin/chown root:wheel "$host_contract_root/authoritative-checkout"
/bin/chmod 0644 "$host_contract_root/authoritative-checkout"
for executable in nucleus-builder-run collider-workspace-shim; do
  target=/usr/local/bin/${executable/collider-workspace-shim/collider}
  if [[ -e "$target" ]] && ! /usr/bin/cmp -s "$script_directory/$executable" "$target"; then
    echo "error: provisioning refuses to replace existing executable: $target" >&2
    exit 73
  fi
  /usr/bin/install -o root -g wheel -m 0755 "$script_directory/$executable" "$target"
done

temporary_plist="$(/usr/bin/mktemp /tmp/nucleus-runner-plist.XXXXXX)"
trap 'registration_token=; /bin/rm -f "$temporary_plist"' EXIT
/bin/cat >"$temporary_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$runner_service_label</string>
  <key>UserName</key><string>$builder_user</string>
  <key>WorkingDirectory</key><string>$runner_root</string>
  <key>ProgramArguments</key><array><string>$runner_root/runsvc.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$builder_home</string>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$runner_logs/runner.log</string>
  <key>StandardErrorPath</key><string>$runner_logs/runner.error.log</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$temporary_plist" >/dev/null
/usr/bin/install -o root -g wheel -m 0644 "$temporary_plist" "$runner_plist"
run_as_builder "$script_directory/install-container-service.sh"
/bin/launchctl bootstrap system "$runner_plist"

"$script_directory/verify-nucleus-builder.sh"
echo "provisioned trusted builder identity and pinned runner $runner_version"
