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
readonly builder_group="$(contract_value builder.group)"
readonly builder_home="$(contract_value builder.home)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly runner_watchdog_service_label="$(contract_value builder.runnerWatchdogServiceLabel)"
readonly container_service_label="$(contract_value launchd.label)"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly developer_uid="$(/usr/bin/id -u "$developer_user")"
readonly runner_root="$(contract_value builder.runnerRoot)"
readonly host_contract_root="$(contract_value builder.hostContractRoot)"
readonly runner_plist="$host_contract_root/$runner_service_label.plist"
readonly runner_watchdog="$host_contract_root/runner-watchdog"
readonly runner_watchdog_plist="$host_contract_root/$runner_watchdog_service_label.plist"
readonly legacy_runner_agent_plist="/Library/LaunchAgents/$runner_service_label.plist"
readonly legacy_runner_plist="/Library/LaunchDaemons/$runner_service_label.plist"
readonly host_execution_lock="$(contract_value builder.hostExecutionLock)"
readonly build_state_group="$(contract_value builder.buildStateGroup)"
readonly build_store=/Library/Nucleus/Collider
readonly runner_work_root="$(contract_value builder.runnerWorkRoot)"

[[ $(/usr/bin/dscl . -read "/Users/$builder_user" IsHidden | /usr/bin/awk '{print $2}') == 1 ]] \
  || fail "$builder_user is not hidden"
[[ $(/usr/bin/dscl . -read "/Users/$builder_user" UserShell | /usr/bin/awk '{print $2}') == /usr/bin/false ]] \
  || fail "$builder_user has an interactive shell"
for group in admin wheel com.apple.access_ssh com.apple.access_remote_ae; do
  /usr/sbin/dseditgroup -o checkmember -m "$builder_user" "$group" 2>/dev/null \
    | /usr/bin/grep -q 'yes' && fail "$builder_user belongs to $group"
done
[[ $(/usr/bin/id -gn "$builder_user") == "$builder_group" ]] \
  || fail "$builder_user primary group is not the dedicated builder group"
# Every local account is a staff member on macOS, so the interactive home must
# grant nothing to group or other. This mode, not group membership, is what
# makes the source boundary an allow list.
for gate_directory in "/Users/$developer_user" "/Users/$developer_user/Developer"; do
  [[ $(/usr/bin/stat -f '%Lp' "$gate_directory") == 700 ]] \
    || fail "traverse gate is reachable by group or other: $gate_directory"
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
# Reading the files is not enough: Git refuses to parse a repository owned by
# another account, and every Collider entry point begins by reading the source
# graph through Git.
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /usr/bin/git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "builder cannot read the checkout through Git"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /usr/bin/git -C "$checkout/third-party/swift-system" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "builder cannot read checkout submodules through Git"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test ! -w "$checkout" || fail "builder can mutate checkout root"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test ! -w "$checkout/.git" || fail "builder can mutate checkout Git metadata"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/test ! -r "/Users/$developer_user/.ssh" \
  || fail "builder can read the developer SSH directory"
# The traverse grant is execute-only, so the home is reachable but not
# enumerable. This is the property that makes the boundary an allow list:
# interactive state created after provisioning is unreachable by default.
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/ls "/Users/$developer_user" >/dev/null 2>&1 \
  && fail "builder can list the developer home"
/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  /bin/ls "/Users/$developer_user/Developer" >/dev/null 2>&1 \
  && fail "builder can list the developer source directory"
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
# The developer reaches the launcher without a password and reaches nothing else
# without one. A grant wider than the launcher would hand a shell to the account
# the source boundary exists to constrain.
readonly sudoers_file=/etc/sudoers.d/nucleus-builder
[[ -f "$sudoers_file" && ! -L "$sudoers_file" ]] || fail "builder sudoers entry is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$sudoers_file") == root:wheel:440 ]] \
  || fail "builder sudoers entry ownership or mode drifted"
/usr/sbin/visudo -c -f "$sudoers_file" >/dev/null || fail "builder sudoers entry is invalid"
# `sudo -l` reports a command as listed under any runas spec, so the grant is
# checked for the target the launcher actually needs: root.
/usr/bin/grep -q "ALL=(root) NOPASSWD: /usr/local/bin/nucleus-builder-run" "$sudoers_file" \
  || fail "launcher grant does not admit the root the launcher requires"
/usr/bin/sudo -n -l -U "$developer_user" /usr/local/bin/nucleus-builder-run >/dev/null 2>&1 \
  || fail "$developer_user cannot run the launcher without a password"
developer_sudo="$(/usr/bin/sudo -n -l -U "$developer_user" 2>&1 || true)"
/usr/bin/grep -q 'NOPASSWD.*nucleus-builder-run' <<<"$developer_sudo" \
  || fail "developer password-free grant does not name the launcher"
/usr/bin/grep -Eq 'NOPASSWD: *(ALL|/bin/|/usr/bin/)' <<<"$developer_sudo" \
  && fail "developer password-free grant reaches beyond the launcher"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' /usr/local/bin/nucleus-builder-run) == root:wheel:755 ]] \
  || fail "constrained launcher ownership or mode drifted"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' /usr/local/bin/collider) == root:wheel:755 ]] \
  || fail "builder Collider shim ownership or mode drifted"
for declared_path in "$runner_root" "$host_contract_root" "$runner_work_root"; do
  [[ "$declared_path" == /* && ! "$declared_path" =~ [[:space:]] ]] \
    || fail "declared builder root is not an absolute whitespace-free path: $declared_path"
done
[[ -f "$host_contract_root/authoritative-checkout" ]] \
  || fail "host checkout contract is absent"
[[ $(/usr/bin/sed -n '1p' "$host_contract_root/authoritative-checkout") == "$checkout" ]] \
  || fail "host checkout contract does not name the authoritative checkout"
# The machine-wide execution lease. Both accounts must be able to lock one inode
# so host execution serializes across them, and neither may be able to replace
# that inode, so neither can bypass the lease by installing its own.
[[ -f "$host_execution_lock" && ! -L "$host_execution_lock" ]] \
  || fail "machine-wide execution lease is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$host_execution_lock") == root:wheel:666 ]] \
  || fail "execution lease ownership or mode drifted"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$host_contract_root") == root:wheel:755 ]] \
  || fail "host contract root ownership or mode drifted"
for lease_account in "$builder_user" "$developer_user"; do
  /usr/bin/sudo -H -u "$lease_account" /bin/test -r "$host_execution_lock" \
    && /usr/bin/sudo -H -u "$lease_account" /bin/test -w "$host_execution_lock" \
    || fail "$lease_account cannot lock the machine-wide execution lease"
  /usr/bin/sudo -H -u "$lease_account" /bin/test ! -w "$host_contract_root" \
    || fail "$lease_account can replace the machine-wide execution lease"
done

# The reading group exists from commissioning; the store itself exists only once
# the migration has filled it, so its contract is checked only when it is there.
/usr/bin/dscl . -read "/Groups/$build_state_group" >/dev/null 2>&1 \
  || fail "build-state group is absent"
/usr/sbin/dseditgroup -o checkmember -m "$developer_user" "$build_state_group" 2>/dev/null \
  | /usr/bin/grep -q 'yes' || fail "$developer_user cannot read the build store"
/usr/sbin/dseditgroup -o checkmember -m "$developer_user" "$builder_group" 2>/dev/null \
  | /usr/bin/grep -q 'yes' && fail "$developer_user belongs to the builder's own group"
[[ ! -L "$build_store" && -d "$build_store" ]] || fail "machine build store is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Mp%Lp' "$build_store") == "$builder_user:$build_state_group:2750" ]] \
  || fail "build store ownership or mode drifted"
[[ $(/usr/bin/stat -f '%Mp%Lp' "$build_store/logs") == 2750 ]] \
  || fail "build store log root is not group-readable with setgid"
[[ $(/usr/bin/stat -f '%Mp%Lp' "$build_store/state/identity") == 0700 ]] \
  || fail "signing identity subtree is readable beyond the builder"
/usr/bin/sudo -H -u "$builder_user" /bin/test -w "$build_store" \
  || fail "$builder_user cannot write the build store"
/usr/bin/sudo -H -u "$developer_user" /bin/test -r "$build_store" \
  || fail "$developer_user cannot read the build store"
/usr/bin/sudo -H -u "$developer_user" /bin/test ! -w "$build_store" \
  || fail "$developer_user can write the build store"
/usr/bin/sudo -H -u "$developer_user" /bin/test ! -w "$build_store/state" \
  || fail "$developer_user can write build state"
/usr/bin/sudo -H -u "$developer_user" /bin/test ! -w "$build_store/logs" \
  || fail "$developer_user can write run history"
/usr/bin/sudo -H -u "$developer_user" /bin/test ! -r "$build_store/state/identity" \
  || fail "$developer_user can read builder signing material"

[[ -f "$runner_root/.runner" ]] || fail "runner registration is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_root") == root:wheel:755 ]] \
  || fail "runner installation is not root-owned and immutable to jobs"
[[ $(/usr/bin/stat -f '%Su:%Sg' "$runner_work_root") == "$builder_user:$builder_group" ]] \
  || fail "runner work checkout is not builder-owned"
foreign_runner_work_path="$(
  /usr/bin/find "$runner_work_root" -xdev ! -user "$builder_user" -print -quit
)"
[[ -z "$foreign_runner_work_path" ]] \
  || fail "runner work ownership drifted: $foreign_runner_work_path"
[[ "$runner_work_root" != "$runner_root"/* ]] \
  || fail "runner work checkout is inside the runner installation"
[[ $(/bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" \
  "$runner_root/bin/Runner.Listener" --version) == "$runner_version" ]] \
  || fail "runner version drifted; install the pinned one with update-nucleus-runner.sh"
[[ $(/usr/bin/plutil -extract agentName raw -o - "$runner_root/.runner") == "$runner_name" ]] \
  || fail "runner name drifted"
[[ $(/usr/bin/plutil -extract poolName raw -o - "$runner_root/.runner") == "$runner_group" ]] \
  || fail "runner group drifted"
[[ -f "$runner_plist" && ! -L "$runner_plist" ]] \
  || fail "runner LaunchAgent descriptor is absent"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_plist") == root:wheel:644 ]] \
  || fail "runner LaunchAgent descriptor ownership or mode drifted"
[[ ! -e "$legacy_runner_agent_plist" && ! -L "$legacy_runner_agent_plist" ]] \
  || fail "global runner LaunchAgent descriptor remains installed"
[[ ! -e "$legacy_runner_plist" && ! -L "$legacy_runner_plist" ]] \
  || fail "legacy runner LaunchDaemon descriptor remains installed"
/bin/launchctl print "user/$builder_uid/$runner_service_label" >/dev/null \
  || fail "runner per-user LaunchAgent is not loaded"
# A runner whose session dies without its process dying leaves a queued job
# waiting against an idle machine, and nothing else on this host can tell that
# state from a runner with no work.
[[ -f "$runner_watchdog" && ! -L "$runner_watchdog" ]] \
  || fail "runner watchdog is not installed"
[[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_watchdog") == root:wheel:755 ]] \
  || fail "runner watchdog ownership or mode drifted"
[[ -f "$runner_watchdog_plist" && ! -L "$runner_watchdog_plist" ]] \
  || fail "runner watchdog LaunchAgent descriptor is not installed"
/bin/launchctl print "user/$builder_uid/$runner_watchdog_service_label" >/dev/null \
  || fail "runner watchdog LaunchAgent is not loaded"
runner_service_pid="$(
  /bin/launchctl print "user/$builder_uid/$runner_service_label" \
    | /usr/bin/awk '/^[[:space:]]*pid = / { print $3; exit }'
)"
[[ -n "$runner_service_pid" \
    && $(/bin/ps -p "$runner_service_pid" -o uid= | /usr/bin/xargs) == "$builder_uid" ]] \
  || fail "runner LaunchAgent is not executing as $builder_user"
runner_service_count=0
while IFS= read -r runner_process_pid; do
  [[ -n "$runner_process_pid" ]] || continue
  runner_service_count=$((runner_service_count + 1))
  [[ $(/bin/ps -p "$runner_process_pid" -o uid= | /usr/bin/xargs) == "$builder_uid" ]] \
    || fail "an orphaned runner service has the wrong effective UID"
done < <(/usr/bin/pgrep -f "^/bin/bash $runner_root/runsvc[.]sh$" || true)
[[ $runner_service_count -eq 1 ]] \
  || fail "expected exactly one runner service, found $runner_service_count"
/bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1 \
  && fail "runner remains loaded in the system launchd domain"
/bin/launchctl print "user/0/$runner_service_label" >/dev/null 2>&1 \
  && fail "runner remains loaded in the root user domain"
/bin/launchctl print "gui/0/$runner_service_label" >/dev/null 2>&1 \
  && fail "runner remains loaded in the root GUI domain"
/bin/launchctl print "gui/$builder_uid/$runner_service_label" >/dev/null 2>&1 \
  && fail "runner remains loaded in the GUI launchd domain"
/bin/launchctl print "user/$developer_uid/$runner_service_label" >/dev/null 2>&1 \
  && fail "runner remains loaded in the developer user domain"
/bin/launchctl print "gui/$developer_uid/$runner_service_label" >/dev/null 2>&1 \
  && fail "runner remains loaded in the developer GUI domain"
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
