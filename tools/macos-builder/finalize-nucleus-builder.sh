#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"

if [[ $EUID -ne 0 || $# -ne 0 ]]; then
  echo "usage: sudo $0" >&2
  exit 64
fi

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}

# Commands run as the builder inherit this working directory, and the builder
# reaches exactly one tree: the checkout. Invoked from anywhere else -- a
# developer home most of all -- those children could not resolve their own
# current directory. Anchor somewhere every identity on this host can read.
cd /

run_as_builder() {
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" "$@"
}

runner_worker_is_active() {
  /bin/ps -axo command= \
    | /usr/bin/awk -v worker="$runner_root/bin/Runner.Worker" \
      '$1 == worker { found = 1 } END { exit(found ? 0 : 1) }'
}

readonly builder_user="$(contract_value builder.user)"
readonly builder_group="$(contract_value builder.group)"
readonly builder_home="$(contract_value builder.home)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly developer_user="$(contract_value builder.developerUser)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly runner_watchdog_service_label="$(contract_value builder.runnerWatchdogServiceLabel)"
readonly runner_watchdog_interval="$(contract_value builder.runnerWatchdogIntervalSeconds)"
readonly boot_coordinator_service_label="$(contract_value builder.bootCoordinatorServiceLabel)"
readonly boot_coordinator_interval="$(contract_value builder.bootCoordinatorIntervalSeconds)"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly developer_uid="$(/usr/bin/id -u "$developer_user")"
readonly runner_root="$(contract_value builder.runnerRoot)"
readonly runner_work="$(contract_value builder.runnerWorkRoot)"
readonly runner_logs="$builder_home/Library/Logs/Nucleus/GitHubActionsRunner"
readonly host_contract_root="$(contract_value builder.hostContractRoot)"
readonly host_execution_lock="$(contract_value builder.hostExecutionLock)"
readonly build_state_group="$(contract_value builder.buildStateGroup)"
readonly build_store=/Library/Nucleus/Collider
readonly runner_plist="$host_contract_root/$runner_service_label.plist"
readonly legacy_runner_agent_plist="/Library/LaunchAgents/$runner_service_label.plist"
readonly legacy_runner_plist="/Library/LaunchDaemons/$runner_service_label.plist"
readonly runner_service_domain="user/$builder_uid"
readonly runner_watchdog="$host_contract_root/runner-watchdog"
readonly runner_watchdog_plist="$host_contract_root/$runner_watchdog_service_label.plist"
readonly runner_watchdog_state="$runner_logs/watchdog.state"
readonly container_service_label="$(contract_value launchd.label)"
readonly container_executable="$(contract_value appleContainer.executable)"
readonly builder_agent_directory="$builder_home/Library/LaunchAgents"
readonly builder_agent_plist="$builder_agent_directory/$container_service_label.plist"
readonly builder_service_directory="$builder_home/Library/Application Support/Nucleus/Collider/service"
readonly builder_service_starter="$builder_service_directory/container-system-start"
readonly boot_coordinator="$host_contract_root/builder-boot-coordinator"
readonly boot_coordinator_plist="/Library/LaunchDaemons/$boot_coordinator_service_label.plist"
readonly boot_coordinator_log="$host_contract_root/builder-boot-coordinator.log"

[[ ! -L "$runner_root" && -d "$runner_root" ]] \
  || { echo "error: registered runner root is not a directory" >&2; exit 73; }
runner_root_contract="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_root")"
[[ "$runner_root_contract" == "$builder_user:$builder_group:755" \
    || "$runner_root_contract" == root:wheel:755 ]] \
  || { echo "error: registered runner root ownership or mode drifted" >&2; exit 73; }
for credential in .credentials .credentials_rsaparams .runner; do
  [[ -f "$runner_root/$credential" && ! -L "$runner_root/$credential" ]] \
    || { echo "error: registered runner credential is absent: $credential" >&2; exit 73; }
done
[[ $(/usr/bin/plutil -extract agentName raw -o - "$runner_root/.runner") == "$runner_name" ]] \
  || { echo "error: registered runner name drifted" >&2; exit 73; }
[[ $(/usr/bin/plutil -extract poolName raw -o - "$runner_root/.runner") == "$runner_group" ]] \
  || { echo "error: registered runner group drifted" >&2; exit 73; }
[[ $(/usr/bin/plutil -extract workFolder raw -o - "$runner_root/.runner") == "$runner_work" ]] \
  || { echo "error: registered runner work directory drifted" >&2; exit 73; }
[[ ! -L "$host_contract_root" ]] \
  || { echo "error: host contract root is a symbolic link" >&2; exit 73; }
if [[ -e "$host_contract_root/authoritative-checkout" ]] \
    && [[ $(/usr/bin/sed -n '1p' "$host_contract_root/authoritative-checkout") != "$checkout" ]]; then
  echo "error: installed authoritative checkout contract differs" >&2
  exit 73
fi
# The checkout is authoritative for these launchers, so a difference means this
# provisioning carries a newer one, not that the host was tampered with;
# refusing on difference would make the launchers unupdatable. A symbolic link
# at the target is still refused, because it would redirect a root-owned entry
# point somewhere this provisioning does not control.
for executable in nucleus-builder-run collider-workspace-shim; do
  target=/usr/local/bin/${executable/collider-workspace-shim/collider}
  [[ ! -L "$target" ]] \
    || { echo "error: installed executable is a symbolic link: $target" >&2; exit 73; }
done

for builder_path in \
  "$runner_logs" \
  "$builder_home/Library/Application Support/Nucleus/Collider" \
  "$builder_home/Library/Developer/Nucleus/Collider" \
  "$builder_home/Library/Caches/Nucleus/Collider" \
  "$builder_home/Library/Logs/Nucleus/Collider" \
  "$runner_root/_diag" \
  "$runner_work"
do
  /usr/bin/install -d -o "$builder_user" -g "$builder_group" -m 0755 "$builder_path"
done
if [[ -e "$runner_root/runsvc.sh" ]]; then
  /usr/bin/cmp -s "$runner_root/bin/runsvc.sh" "$runner_root/runsvc.sh" \
    || { echo "error: installed runner service launcher drifted" >&2; exit 73; }
else
  /bin/cp "$runner_root/bin/runsvc.sh" "$runner_root/runsvc.sh"
fi
/bin/chmod 0755 "$runner_root/runsvc.sh"
/usr/sbin/chown -R root:wheel "$runner_root"
/usr/sbin/chown -R "$builder_user":"$builder_group" "$runner_root/_diag"
# The work root is outside the immutable installation and belongs entirely to
# Actions: retained checkouts, action caches, tool state, and bookkeeping are
# all ephemeral job state. Reconcile the whole bounded tree when replacing a
# retired service identity. `find` does not follow symlinks, so a job-created
# link cannot extend this ownership change beyond the declared work root.
/usr/bin/find "$runner_work" -xdev \
  -exec /usr/sbin/chown -h "$builder_user:$builder_group" {} +
/bin/chmod 0755 "$runner_root/_diag" "$runner_work"
for credential in .credentials .credentials_rsaparams .runner; do
  /usr/sbin/chown root:"$builder_group" "$runner_root/$credential"
  /bin/chmod 0640 "$runner_root/$credential"
done

/usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$host_contract_root")"
/usr/bin/install -d -o root -g wheel -m 0755 "$host_contract_root"
[[ ! -L "$boot_coordinator" && ! -L "$boot_coordinator_plist" ]] \
  || { echo "error: boot coordinator installation target is a symbolic link" >&2; exit 73; }
/usr/bin/install -o root -g wheel -m 0755 \
  "$script_directory/builder-boot-coordinator" "$boot_coordinator"
printf '%s\n' "$checkout" >"$host_contract_root/authoritative-checkout"
/usr/sbin/chown root:wheel "$host_contract_root/authoritative-checkout"
/bin/chmod 0644 "$host_contract_root/authoritative-checkout"
# The machine-wide Collider execution lease. Every account may open and lock
# this file; none may replace it, because the directory holding it is writable
# only by root. That is what lets the builder and the interactive developer
# serialize host execution against one inode without either reading the other's
# storage. Create it in place rather than installing over it: replacing the
# inode would silently release a lock a running build still believes it holds.
[[ "$host_execution_lock" == "$host_contract_root"/* ]] \
  || { echo "error: execution lease is outside the host contract root" >&2; exit 78; }
/usr/bin/touch "$host_execution_lock"
[[ -f "$host_execution_lock" && ! -L "$host_execution_lock" ]] \
  || { echo "error: execution lease is not a regular file" >&2; exit 73; }
/usr/sbin/chown root:wheel "$host_execution_lock"
/bin/chmod -N "$host_execution_lock"
/bin/chmod 0666 "$host_execution_lock"
# The group that reads the machine-wide build store. Two accounts execute on
# this host and the state they share belongs to neither home, so the builder
# owns and writes that store while this group reads it, which is what lets the
# interactive developer inspect run records and finished artifacts without
# privilege and without the builder's home becoming readable.
if ! /usr/bin/dscl . -read "/Groups/$build_state_group" >/dev/null 2>&1; then
  build_state_gid=400
  while /usr/bin/dscl . -list /Groups PrimaryGroupID \
      | /usr/bin/awk '{print $2}' | /usr/bin/grep -qx "$build_state_gid"; do
    build_state_gid=$((build_state_gid + 1))
    [[ "$build_state_gid" -lt 500 ]] \
      || { echo "error: no free service GID for $build_state_group" >&2; exit 78; }
  done
  /usr/bin/dscl . -create "/Groups/$build_state_group"
  /usr/bin/dscl . -create "/Groups/$build_state_group" PrimaryGroupID "$build_state_gid"
  /usr/bin/dscl . -create "/Groups/$build_state_group" RealName \
    "Nucleus Collider build state readers"
fi
# The developer reads the store; the builder writes it as its owner. Neither
# membership grants the other's, so the reading group never reaches the runner
# registration credentials the builder's own group gates.
/usr/sbin/dseditgroup -o edit -a "$developer_user" -t user "$build_state_group" 2>/dev/null || true
# The machine-wide build store. `install -d` drops the setgid bit, so every mode
# is applied again with chmod: without setgid, objects the builder creates take
# the builder's own group and the reading group never sees them.
/usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$build_store")"
/usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 2750 "$build_store"
/bin/chmod 2750 "$build_store"
for store_directory in configuration state cache; do
  /usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 2750 \
    "$build_store/$store_directory"
  /bin/chmod 2750 "$build_store/$store_directory"
done
# Only builder-domain commands create durable run records. Inspection and dry
# planning stay in the developer account and read the store without writing it,
# so logs follow the same owner-write/group-read contract as all other shared
# state.
/usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 2750 \
  "$build_store/logs"
/usr/sbin/chown -R "$builder_user:$build_state_group" "$build_store/logs"
/usr/bin/find "$build_store/logs" -type d -exec /bin/chmod 2750 {} +
/usr/bin/find "$build_store/logs" -type f -exec /bin/chmod 0640 {} +

# State retained before shared-store durable writes gained group read remains
# valid and must not be rebuilt merely to change its access mode. Normalize the
# bounded task-record namespace once; new records are born 0640.
task_state_root="$build_store/state/build/state/tasks"
if [[ -d "$task_state_root" ]]; then
  /usr/sbin/chown -R "$builder_user:$build_state_group" "$task_state_root"
  /usr/bin/find "$task_state_root" -type d -exec /bin/chmod 2750 {} +
  /usr/bin/find "$task_state_root" -type f -exec /bin/chmod 0640 {} +
fi
# Signing material is the one subtree the reading group must not reach: the
# identity that executes is the identity that signs.
/usr/bin/install -d -o "$builder_user" -g "$build_state_group" -m 0700 \
  "$build_store/state/identity"
/bin/chmod 0700 "$build_store/state/identity"

for executable in nucleus-builder-run collider-workspace-shim; do
  target=/usr/local/bin/${executable/collider-workspace-shim/collider}
  /usr/bin/install -o root -g wheel -m 0755 "$script_directory/$executable" "$target"
done

# One scoped, password-free path from the developer to the build launcher. The
# run-as target is root because the launcher itself drops to the builder through
# launchd; granting it as the builder would leave every local build prompting.
# Without it every local build prompts, and a build that prompts is a build that
# gets run some other way. The grant is one exact root-owned program that takes
# only a canonical checkout, a typed operation, and a declared configuration,
# and grants no shell; the identity it runs code as has no sudo, no keys, and no
# read access to the interactive home, so it lowers privilege rather than
# raising it. Validated before installation, because an unparsable file in
# sudoers.d disables sudo for every user on the host.
readonly sudoers_file=/etc/sudoers.d/nucleus-builder
temporary_sudoers="$(/usr/bin/mktemp /tmp/nucleus-sudoers.XXXXXX)"
trap '/bin/rm -f "$temporary_sudoers" "${temporary_plist:-}" "${temporary_watchdog_plist:-}" "${temporary_boot_coordinator_plist:-}"' EXIT
/bin/cat >"$temporary_sudoers" <<SUDOERS
# Installed by tools/macos-builder/finalize-nucleus-builder.sh. Do not edit.
$developer_user ALL=(root) NOPASSWD: /usr/local/bin/nucleus-builder-run
SUDOERS
/usr/sbin/visudo -c -f "$temporary_sudoers" >/dev/null \
  || { echo "error: generated sudoers entry is invalid" >&2; exit 78; }
/usr/bin/install -o root -g wheel -m 0440 "$temporary_sudoers" "$sudoers_file"

# The EXIT trap installed above already removes this file.
temporary_plist="$(/usr/bin/mktemp /tmp/nucleus-runner-plist.XXXXXX)"
/bin/cat >"$temporary_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$runner_service_label</string>
  <key>LimitLoadToSessionType</key><array>
    <string>Aqua</string>
    <string>Background</string>
  </array>
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
if [[ -e "$runner_plist" || -L "$runner_plist" ]]; then
  [[ -f "$runner_plist" && ! -L "$runner_plist" ]] \
    || { echo "error: runner LaunchAgent descriptor is not a regular file" >&2; exit 73; }
  [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_plist") == root:wheel:644 ]] \
    || { echo "error: runner LaunchAgent descriptor ownership or mode drifted" >&2; exit 73; }
  if ! /usr/bin/cmp -s "$temporary_plist" "$runner_plist" \
      && /bin/launchctl print "$runner_service_domain/$runner_service_label" >/dev/null 2>&1; then
    if runner_worker_is_active; then
      echo "error: a job is executing on the runner being updated" >&2
      exit 75
    fi
    /bin/launchctl bootout "$runner_service_domain/$runner_service_label"
  fi
fi
/usr/bin/install -o root -g wheel -m 0644 "$temporary_plist" "$runner_plist"
for builder_service_directory_path in \
  "$builder_agent_directory" \
  "$builder_service_directory"
do
  /usr/bin/install -d -o "$builder_user" -g "$builder_group" -m 0755 "$builder_service_directory_path"
  /bin/chmod -N "$builder_service_directory_path"
done
for builder_service_file in \
  "$builder_agent_plist" \
  "$builder_service_starter"
do
  if [[ -e "$builder_service_file" || -L "$builder_service_file" ]]; then
    [[ -f "$builder_service_file" && ! -L "$builder_service_file" ]] \
      || { echo "error: builder service target is not a regular file" >&2; exit 73; }
    /usr/bin/chflags nouchg,noschg "$builder_service_file"
    /bin/chmod -N "$builder_service_file"
    /usr/sbin/chown "$builder_user":"$builder_group" "$builder_service_file"
    /bin/chmod 0644 "$builder_service_file"
  fi
done
# Git refuses to parse a repository owned by another account, which is exactly
# the arrangement this identity exists for: the builder reads the developer's
# checkout and must never own it. The exception is granted for that checkout and
# the repositories beneath it, because every submodule is a repository with the
# same ownership. It is scoped to those paths rather than disabling the check.
/bin/launchctl print "$runner_service_domain" >/dev/null 2>&1 \
  || /bin/launchctl bootstrap "$runner_service_domain"
run_as_builder /usr/bin/git config --global --replace-all safe.directory "$checkout"
run_as_builder /usr/bin/git config --global --add safe.directory "$checkout/*"
# The same refusal in the other direction. Resolving a package graph
# materializes dependency checkouts into the store, which the builder owns, and
# the developer reads them when planning a run or describing a dry run. Both
# accounts are this host's own build identities, so each is told the other's
# repositories are not a stranger's.
/usr/bin/sudo -u "$developer_user" /usr/bin/git config --global \
  --replace-all safe.directory "$build_store"
/usr/bin/sudo -u "$developer_user" /usr/bin/git config --global \
  --add safe.directory "$build_store/*"

# Installing the container service stops every running container to restart the
# API server under it. A build executing at that moment loses its containers
# mid-task and fails, so the job check has to happen before this rather than
# only before the runner is rehomed further down: by then the damage is done.
if runner_worker_is_active; then
  echo "error: a job is executing; restarting the container service would fail it" >&2
  exit 75
fi
run_as_builder "$script_directory/install-container-service.sh"
# Apple Container registers its XPC API in the builder's per-user launchd
# domain. The Actions listener must inhabit that same domain; a LaunchDaemon
# running as the same UID is still in the system bootstrap namespace and cannot
# resolve the per-user Mach service.
# A global LaunchAgent is loaded independently into login and background
# sessions, while an explicit bootstrap adds another instance. Keep the runner
# descriptor in the root-owned host-contract directory instead and drain every
# legacy domain. Preserve an already-correct builder service: restarting it
# leaves a broker session behind temporarily and delays otherwise idle CI.
if runner_worker_is_active; then
  echo "error: a job is executing on the runner being rehomed" >&2
  exit 75
fi
/bin/rm -f "$legacy_runner_agent_plist" "$legacy_runner_plist"
for runner_domain in \
  system \
  user/0 \
  gui/0 \
  "gui/$builder_uid" \
  "user/$developer_uid" \
  "gui/$developer_uid"
do
  /bin/launchctl bootout "$runner_domain/$runner_service_label" >/dev/null 2>&1 || true
done

# A service that is not loaded is one of the two answers this asks for, and
# `launchctl print` reports it by failing. Under `set -o pipefail` that failure
# propagates out of the substitution and ends the script with no message at all,
# which is how finalization came to abort in silence whenever it ran against a
# stopped runner -- the state the updater deliberately creates before it swaps
# the installation. The emptiness is handled immediately below.
current_runner_service_pid="$(
  /bin/launchctl print "$runner_service_domain/$runner_service_label" 2>/dev/null \
    | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }' || true
)"
current_runner_service_is_healthy=false
if [[ -n "$current_runner_service_pid" \
    && $(/bin/ps -p "$current_runner_service_pid" -o uid= | /usr/bin/xargs) == "$builder_uid" ]]; then
  current_runner_service_is_healthy=true
else
  /bin/launchctl bootout \
    "$runner_service_domain/$runner_service_label" >/dev/null 2>&1 || true
  current_runner_service_pid=""
fi

stale_runner_service_pids=()
while IFS= read -r runner_service_pid; do
  [[ -n "$runner_service_pid" ]] || continue
  if [[ "$runner_service_pid" != "$current_runner_service_pid" ]]; then
    stale_runner_service_pids+=("$runner_service_pid")
  fi
done < <(/usr/bin/pgrep -f "^/bin/bash $runner_root/runsvc[.]sh$" || true)
remaining_runner_services=0
if [[ ${#stale_runner_service_pids[@]} -gt 0 ]]; then
  # A booted-out KeepAlive job may finish between the snapshot and signal.
  # Cleanup is complete in that case, so signal each still-live PID separately.
  for runner_service_pid in "${stale_runner_service_pids[@]}"; do
    /bin/kill -TERM "$runner_service_pid" >/dev/null 2>&1 || true
  done
  for attempt in {1..10}; do
    remaining_runner_services=0
    for runner_service_pid in "${stale_runner_service_pids[@]}"; do
      if /bin/kill -0 "$runner_service_pid" >/dev/null 2>&1; then
        remaining_runner_services=$((remaining_runner_services + 1))
      fi
    done
    [[ $remaining_runner_services -eq 0 ]] && break
    /bin/sleep 1
  done
fi
[[ $remaining_runner_services -eq 0 ]] \
  || { echo "error: stale runner service did not terminate" >&2; exit 75; }
if [[ "$current_runner_service_is_healthy" == false ]]; then
  run_as_builder /bin/launchctl bootstrap "$runner_service_domain" "$runner_plist"
fi

# The runner's broker session can die while its process stays up, which leaves a
# queued job waiting against a machine that looks idle and healthy. launchd
# cannot see that, because nothing exited. The watchdog is what notices, and it
# runs as the builder because only the builder may inspect its own runner and
# restart its own service.
/usr/bin/install -o root -g wheel -m 0755 \
  "$script_directory/runner-watchdog" "$runner_watchdog"
temporary_watchdog_plist="$(/usr/bin/mktemp /tmp/nucleus-runner-watchdog-plist.XXXXXX)"
/bin/cat >"$temporary_watchdog_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$runner_watchdog_service_label</string>
  <key>LimitLoadToSessionType</key><array>
    <string>Aqua</string>
    <string>Background</string>
  </array>
  <key>ProgramArguments</key><array>
    <string>$runner_watchdog</string>
    <string>$runner_root</string>
    <string>$runner_service_domain/$runner_service_label</string>
    <string>$runner_watchdog_state</string>
  </array>
  <key>StartInterval</key><integer>$runner_watchdog_interval</integer>
  <key>RunAtLoad</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$runner_logs/watchdog.log</string>
  <key>StandardErrorPath</key><string>$runner_logs/watchdog.log</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$temporary_watchdog_plist" >/dev/null
/usr/bin/install -o root -g wheel -m 0644 \
  "$temporary_watchdog_plist" "$runner_watchdog_plist"
/bin/rm -f "$temporary_watchdog_plist"
# Restarting the watchdog costs nothing: it holds no session and each run is one
# short check, so it is reloaded unconditionally rather than compared.
/bin/launchctl bootout \
  "$runner_service_domain/$runner_watchdog_service_label" >/dev/null 2>&1 || true
run_as_builder /bin/launchctl bootstrap \
  "$runner_service_domain" "$runner_watchdog_plist"

# The per-user bootstrap namespace is volatile across a machine reboot, and the
# hidden builder never logs in to recreate it. This root daemon owns only that
# lifecycle edge: it recreates the user domain, restores the container service,
# then exposes the runner after the local execution substrate is healthy.
temporary_boot_coordinator_plist="$(/usr/bin/mktemp /tmp/nucleus-boot-coordinator-plist.XXXXXX)"
/bin/cat >"$temporary_boot_coordinator_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$boot_coordinator_service_label</string>
  <key>ProgramArguments</key><array>
    <string>$boot_coordinator</string>
    <string>$builder_user</string>
    <string>$builder_uid</string>
    <string>$container_service_label</string>
    <string>$builder_agent_plist</string>
    <string>$container_executable</string>
    <string>$runner_service_label</string>
    <string>$runner_plist</string>
    <string>$runner_root</string>
    <string>$runner_watchdog_service_label</string>
    <string>$runner_watchdog_plist</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$boot_coordinator_interval</integer>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$boot_coordinator_log</string>
  <key>StandardErrorPath</key><string>$boot_coordinator_log</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$temporary_boot_coordinator_plist" >/dev/null
/usr/bin/install -o root -g wheel -m 0644 \
  "$temporary_boot_coordinator_plist" "$boot_coordinator_plist"
/bin/rm -f "$temporary_boot_coordinator_plist"
/bin/launchctl bootout \
  "system/$boot_coordinator_service_label" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$boot_coordinator_plist"

"$script_directory/verify-nucleus-builder.sh"
echo "finalized trusted builder identity and pinned runner $runner_version"
