#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
if [[ $EUID -ne 0 || $# -ne 0 ]]; then
  echo "usage: sudo $0" >&2
  exit 64
fi
contract_value() { /usr/bin/plutil -extract "$1" raw -o - "$contract"; }
fail() { echo "error: $*" >&2; exit 77; }

readonly builder_user="$(contract_value builder.user)"
readonly builder_home="$(contract_value builder.home)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly container_service_label="$(contract_value launchd.label)"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly runner_root="/Library/Application Support/Nucleus/GitHubActionsRunner"

[[ $(/usr/bin/dscl . -read "/Users/$builder_user" IsHidden | /usr/bin/awk '{print $2}') == 1 ]] \
  || fail "$builder_user is not hidden"
[[ $(/usr/bin/dscl . -read "/Users/$builder_user" UserShell | /usr/bin/awk '{print $2}') == /usr/bin/false ]] \
  || fail "$builder_user has an interactive shell"
for group in admin wheel com.apple.access_ssh com.apple.access_remote_ae; do
  /usr/sbin/dseditgroup -o checkmember -m "$builder_user" "$group" 2>/dev/null \
    | /usr/bin/grep -q 'yes' && fail "$builder_user belongs to $group"
done
/usr/sbin/sysadminctl -secureTokenStatus "$builder_user" 2>&1 \
  | /usr/bin/grep -q 'DISABLED' || fail "$builder_user has a Secure Token"
/usr/bin/fdesetup list 2>/dev/null | /usr/bin/grep -q "^$builder_user," \
  && fail "$builder_user can unlock FileVault"
sudo_access="$(/usr/bin/sudo -n -l -U "$builder_user" 2>&1 || true)"
/usr/bin/grep -Eq 'not allowed|may not run sudo' <<<"$sudo_access" \
  || fail "$builder_user has a sudo path"

/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test -r "$checkout/Package.swift" || fail "builder cannot read checkout"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test ! -w "$checkout" || fail "builder can mutate checkout root"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test ! -w "$checkout/.git" || fail "builder can mutate checkout Git metadata"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test ! -r "/Users/$developer_user/.ssh" \
  || fail "builder can read the developer SSH directory"
while IFS= read -r -d '' unrelated_path; do
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
    /bin/test ! -x "$unrelated_path" \
    || fail "builder can traverse unrelated developer state: $unrelated_path"
done < <(/usr/bin/find "/Users/$developer_user" -mindepth 1 -maxdepth 1 \
  ! -name Developer -print0)
while IFS= read -r -d '' unrelated_path; do
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
    /bin/test ! -x "$unrelated_path" \
    || fail "builder can traverse unrelated source: $unrelated_path"
done < <(/usr/bin/find "/Users/$developer_user/Developer" -mindepth 1 -maxdepth 1 \
  ! -path "$checkout" -print0)

[[ -x /usr/local/bin/nucleus-builder-run ]] || fail "constrained launcher is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' /usr/local/bin/nucleus-builder-run) == root:wheel:755 ]] \
  || fail "constrained launcher ownership or mode drifted"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' /usr/local/bin/collider) == root:wheel:755 ]] \
  || fail "builder Collider shim ownership or mode drifted"
[[ -f "$runner_root/.runner" ]] || fail "runner registration is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_root") == root:wheel:755 ]] \
  || fail "runner installation is not root-owned and immutable to jobs"
[[ $(/usr/bin/stat -f '%Su:%Sg' "$runner_root/_work") == "$builder_user:staff" ]] \
  || fail "runner work checkout is not builder-owned"
[[ $(/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  "$runner_root/bin/Runner.Listener" --version) == "$runner_version" ]] \
  || fail "runner version drifted"
[[ $(/usr/bin/plutil -extract agentName raw -o - "$runner_root/.runner") == "$runner_name" ]] \
  || fail "runner name drifted"
[[ $(/usr/bin/plutil -extract poolName raw -o - "$runner_root/.runner") == "$runner_group" ]] \
  || fail "runner group drifted"
/bin/launchctl print "system/$runner_service_label" >/dev/null \
  || fail "runner LaunchDaemon is not loaded"
/bin/launchctl print "user/$builder_uid/$container_service_label" >/dev/null \
  || fail "builder Apple-container service is not loaded"

identity_output="$(/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /usr/bin/security find-identity -v -p codesigning 2>&1 || true)"
/usr/bin/grep -q '0 valid identities found' <<<"$identity_output" \
  || fail "builder has a code-signing identity"
for path in .ssh .aws .config/gh .config/rclone .cloudflared; do
  [[ ! -e "$builder_home/$path" ]] || fail "builder has publication-capable state: $path"
done
[[ ! -e "$builder_home/Library/Application Support/com.apple.TCC/TCC.db" ]] \
  || fail "builder has a personal TCC database"
[[ ! -e "$builder_home/Library/Preferences/MobileMeAccounts.plist" ]] \
  || fail "builder has an iCloud account"

echo "verified isolated $builder_user account, read-only source view, services, and credentials boundary"
