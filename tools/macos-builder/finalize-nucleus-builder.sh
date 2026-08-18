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
run_as_builder() {
  /bin/launchctl asuser "$builder_uid" /usr/bin/sudo -H -u "$builder_user" "$@"
}

readonly builder_user="$(contract_value builder.user)"
readonly builder_group="$(contract_value builder.group)"
readonly builder_home="$(contract_value builder.home)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly runner_group="$(contract_value builder.runnerGroup)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly builder_uid="$(/usr/bin/id -u "$builder_user")"
readonly runner_root="$(contract_value builder.runnerRoot)"
readonly runner_work="$(contract_value builder.runnerWorkRoot)"
readonly runner_logs="$builder_home/Library/Logs/Nucleus/GitHubActionsRunner"
readonly host_contract_root="$(contract_value builder.hostContractRoot)"
readonly runner_plist="/Library/LaunchDaemons/$runner_service_label.plist"
readonly container_service_label="$(contract_value launchd.label)"
readonly builder_agent_directory="$builder_home/Library/LaunchAgents"
readonly builder_agent_plist="$builder_agent_directory/$container_service_label.plist"
readonly builder_service_directory="$builder_home/Library/Application Support/Nucleus/Collider/service"
readonly builder_service_starter="$builder_service_directory/container-system-start"

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
for executable in nucleus-builder-run collider-workspace-shim; do
  target=/usr/local/bin/${executable/collider-workspace-shim/collider}
  if [[ ( -e "$target" || -L "$target" ) ]] \
      && { [[ -L "$target" ]] || ! /usr/bin/cmp -s "$script_directory/$executable" "$target"; }; then
    echo "error: installed executable differs: $target" >&2
    exit 73
  fi
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
# The work root is outside the installation the recursive pass above owns, so
# its checkout keeps builder ownership without a recursive walk of every
# submodule working tree.
/usr/sbin/chown "$builder_user":"$builder_group" "$runner_work"
/bin/chmod 0755 "$runner_root/_diag" "$runner_work"
for credential in .credentials .credentials_rsaparams .runner; do
  /usr/sbin/chown root:"$builder_group" "$runner_root/$credential"
  /bin/chmod 0640 "$runner_root/$credential"
done

/usr/bin/install -d -o root -g wheel -m 0755 "$(/usr/bin/dirname "$host_contract_root")"
/usr/bin/install -d -o root -g wheel -m 0755 "$host_contract_root"
printf '%s\n' "$checkout" >"$host_contract_root/authoritative-checkout"
/usr/sbin/chown root:wheel "$host_contract_root/authoritative-checkout"
/bin/chmod 0644 "$host_contract_root/authoritative-checkout"
for executable in nucleus-builder-run collider-workspace-shim; do
  target=/usr/local/bin/${executable/collider-workspace-shim/collider}
  /usr/bin/install -o root -g wheel -m 0755 "$script_directory/$executable" "$target"
done

temporary_plist="$(/usr/bin/mktemp /tmp/nucleus-runner-plist.XXXXXX)"
trap '/bin/rm -f "$temporary_plist"' EXIT
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
if [[ ( -e "$runner_plist" || -L "$runner_plist" ) ]] \
    && { [[ -L "$runner_plist" ]] || ! /usr/bin/cmp -s "$temporary_plist" "$runner_plist"; }; then
  echo "error: installed runner service contract differs" >&2
  exit 73
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
run_as_builder "$script_directory/install-container-service.sh"
if ! /bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1; then
  /bin/launchctl bootstrap system "$runner_plist"
fi

"$script_directory/verify-nucleus-builder.sh"
echo "finalized trusted builder identity and pinned runner $runner_version"
