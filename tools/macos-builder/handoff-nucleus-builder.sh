#!/bin/bash
set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly contract="$script_directory/contract.json"
readonly state_library="$script_directory/handoff-state.sh"
readonly organization="nucleus-os"
readonly repository_name="nucleus"

if [[ $EUID -eq 0 || $# -ne 0 ]]; then
  echo "usage: $0  # run as the authenticated interactive developer" >&2
  exit 64
fi
if [[ ! -r "$contract" || ! -r "$state_library" ]]; then
  echo "error: handoff contract or state library is unreadable" >&2
  exit 72
fi
source "$state_library"

contract_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$contract"
}
stage() {
  printf 'handoff: %s\n' "$1" >&2
}
fail() {
  echo "error: $*" >&2
  exit 70
}

readonly expected_user="$(contract_value builder.developerUser)"
readonly builder_user="$(contract_value builder.user)"
readonly builder_home="$(contract_value builder.home)"
readonly checkout="$(contract_value builder.authoritativeCheckout)"
readonly group_name="$(contract_value builder.runnerGroup)"
readonly runner_name="$(contract_value builder.runnerName)"
readonly runner_label="$(contract_value builder.runnerLabel)"
readonly runner_version="$(contract_value builder.runnerVersion)"
readonly expected_archive_sha="$(contract_value builder.runnerArchiveSHA256)"
readonly expected_archive_size="$(contract_value builder.runnerArchiveSize)"
readonly runner_service_label="$(contract_value builder.runnerServiceLabel)"
readonly runner_root="/Library/Application Support/Nucleus/GitHubActionsRunner"
readonly archive="$HOME/Library/Caches/Nucleus/Collider/provisioning/actions-runner-osx-arm64-$runner_version.tar.gz"
readonly workflow="nucleus-os/nucleus/.github/workflows/ci.yml@refs/heads/main"

stage "validating local inputs"
[[ $(/usr/bin/id -un) == "$expected_user" ]] \
  || fail "handoff must run as $expected_user"
[[ -f "$archive" ]] || fail "prepared runner archive is absent: $archive"
[[ $(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}') == "$expected_archive_sha" ]] \
  || fail "prepared runner archive digest drifted"
[[ $(/usr/bin/stat -f '%z' "$archive") == "$expected_archive_size" ]] \
  || fail "prepared runner archive size drifted"
[[ "$(cd "$checkout" && /bin/pwd -P)" == "$checkout" ]] \
  || fail "authoritative checkout is not canonical: $checkout"
for required_file in \
  "$script_directory/builder-acl.sh" \
  "$script_directory/finalize-nucleus-builder.sh" \
  "$script_directory/provision-nucleus-builder.sh" \
  "$script_directory/verify-nucleus-builder.sh"
do
  [[ -x "$required_file" ]] || fail "required handoff input is not executable: $required_file"
done

account_presence=absent
service_presence=absent
local_recovery=absent
/usr/bin/dscl . -read "/Users/$builder_user" >/dev/null 2>&1 \
  && account_presence=present
(/bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1) \
  && service_presence=present
if [[ "$account_presence" == present && "$service_presence" == absent ]]; then
  local_recovery=pre-artifact
  finalization_footprint=absent
  for provisioning_path in \
    "/Library/Application Support/Nucleus/Builder" \
    "/Library/LaunchDaemons/$runner_service_label.plist" \
    /usr/local/bin/collider \
    /usr/local/bin/nucleus-builder-run
  do
    [[ ! -e "$provisioning_path" && ! -L "$provisioning_path" ]] \
      || finalization_footprint=present
  done
  if [[ -L "$builder_home" ]]; then
    local_recovery=absent
  elif [[ -e "$builder_home" ]] \
      && [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$builder_home") != "$builder_user:staff:700" ]]; then
    local_recovery=absent
  fi
  if [[ "$local_recovery" == pre-artifact && ( -e "$runner_root" || -L "$runner_root" ) ]]; then
    local_recovery=absent
    if [[ ! -L "$runner_root" && -d "$runner_root" && -x "$runner_root/config.sh" ]]; then
      runner_root_contract="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runner_root")"
      if [[ "$runner_root_contract" == "$builder_user:staff:755" ]] \
          && [[ "$finalization_footprint" == absent ]] \
          && [[ ! -e "$runner_root/.runner" && ! -L "$runner_root/.runner" ]] \
          && [[ ! -e "$runner_root/.credentials" && ! -L "$runner_root/.credentials" ]]; then
        local_recovery=unregistered
      elif [[ "$runner_root_contract" == root:wheel:755 ]] \
          && [[ -f "$runner_root/.runner" && ! -L "$runner_root/.runner" ]] \
          && [[ -f "$runner_root/.credentials" && ! -L "$runner_root/.credentials" ]] \
          && [[ -f "$runner_root/.credentials_rsaparams" \
            && ! -L "$runner_root/.credentials_rsaparams" ]] \
          && [[ $(/usr/bin/plutil -extract agentName raw -o - "$runner_root/.runner") == "$runner_name" ]] \
          && [[ $(/usr/bin/plutil -extract poolName raw -o - "$runner_root/.runner") == "$group_name" ]]; then
        local_recovery=registered
      fi
    fi
  elif [[ "$finalization_footprint" == present ]]; then
    local_recovery=absent
  fi
fi
local_state="$(nucleus_handoff_local_state \
  "$account_presence" "$service_presence" "$local_recovery")"
[[ "$local_state" != inconsistent ]] \
  || fail "local builder provisioning is partial; inspect it before retrying"

stage "validating GitHub authorization"
command -v gh >/dev/null || { echo "error: gh is required" >&2; exit 69; }
if ! gh auth status -h github.com 2>&1 \
  | /usr/bin/grep -Eq "Token scopes:.*'admin:org'"; then
  echo "error: GitHub authorization must include admin:org" >&2
  echo "run: gh auth refresh -h github.com -s admin:org" >&2
  exit 77
fi

stage "reconciling the protected runner group"
repo_id="$(gh api "repos/$organization/$repository_name" --jq .id)"
group_id="$(gh api "orgs/$organization/actions/runner-groups" \
  --jq ".runner_groups[] | select(.name == \"$group_name\") | .id")"
if [[ -z "$group_id" ]]; then
  group_id="$(gh api --method POST "orgs/$organization/actions/runner-groups" \
    -f name="$group_name" \
    -f visibility=selected \
    -F allows_public_repositories=true \
    -F restricted_to_workflows=true \
    -f "selected_workflows[]=$workflow" \
    --jq .id)"
else
  gh api --method PATCH "orgs/$organization/actions/runner-groups/$group_id" \
    -f name="$group_name" \
    -f visibility=selected \
    -F allows_public_repositories=true \
    -F restricted_to_workflows=true \
    -f "selected_workflows[]=$workflow" >/dev/null
fi
gh api --method PUT \
  "orgs/$organization/actions/runner-groups/$group_id/repositories" \
  -F "selected_repository_ids[]=$repo_id" >/dev/null
[[ $(gh api "orgs/$organization/actions/runner-groups/$group_id" --jq .visibility) == selected ]] \
  || { echo "error: runner group visibility drifted" >&2; exit 70; }
[[ $(gh api "orgs/$organization/actions/runner-groups/$group_id" --jq .restricted_to_workflows) == true ]] \
  || { echo "error: runner group workflow restriction is disabled" >&2; exit 70; }
gh api "orgs/$organization/actions/runner-groups/$group_id" --jq '.selected_workflows[]' \
  | /usr/bin/grep -Fxq "$workflow" \
  || { echo "error: runner group workflow allowlist drifted" >&2; exit 70; }
configured_repository_ids="$(gh api \
  "orgs/$organization/actions/runner-groups/$group_id/repositories" \
  --jq '.repositories[].id')"
[[ "$configured_repository_ids" == "$repo_id" ]] \
  || { echo "error: runner group repository allowlist drifted" >&2; exit 70; }
existing_runner_names="$(gh api \
  "orgs/$organization/actions/runner-groups/$group_id/runners" \
  --jq '.runners[].name')"
runner_state="$(nucleus_handoff_runner_state "$existing_runner_names" "$runner_name")"
handoff_action="$(nucleus_handoff_action "$local_state" "$runner_state")"
[[ "$handoff_action" != inconsistent ]] || {
  echo "error: local state is $local_state but runner-group state is $runner_state" >&2
  echo "error: provisioning never replaces or guesses at partial state" >&2
  exit 73
}

case "$handoff_action" in
  provision)
    stage "provisioning the isolated builder identity"
    registration_token="$(gh api --method POST \
      "orgs/$organization/actions/runners/registration-token" \
      --jq .token)"
    trap 'registration_token=' EXIT
    printf '%s\n' "$registration_token" | /usr/bin/sudo \
      "$script_directory/provision-nucleus-builder.sh" "$archive"
    registration_token=''
    ;;
  verify)
    stage "re-verifying completed local provisioning"
    /usr/bin/sudo "$script_directory/verify-nucleus-builder.sh"
    ;;
  finalize)
    stage "finalizing the registered builder identity"
    /usr/bin/sudo "$script_directory/finalize-nucleus-builder.sh"
    ;;
esac

stage "waiting for the registered runner"
registered_runner_name=""
runner_status=""
for attempt in {1..60}; do
  registered_runner_name="$(gh api "orgs/$organization/actions/runners" \
    --jq ".runners[] | select(.name == \"$runner_name\") | .name")"
  runner_status="$(gh api "orgs/$organization/actions/runners" \
    --jq ".runners[] | select(.name == \"$runner_name\") | .status")"
  [[ "$registered_runner_name" == "$runner_name" && "$runner_status" == online ]] && break
  /bin/sleep 1
done
[[ "$registered_runner_name" == "$runner_name" ]] \
  || { echo "error: provisioned runner is not registered" >&2; exit 70; }
[[ "$runner_status" == online ]] \
  || { echo "error: provisioned runner did not become online" >&2; exit 70; }
runner_labels="$(gh api "orgs/$organization/actions/runners" \
  --jq ".runners[] | select(.name == \"$runner_name\") | .labels[].name")"
/usr/bin/grep -Fxq "$runner_label" <<<"$runner_labels" \
  || { echo "error: provisioned runner label is absent" >&2; exit 70; }
configured_runner_names="$(gh api \
  "orgs/$organization/actions/runner-groups/$group_id/runners" \
  --jq '.runners[].name')"
[[ "$configured_runner_names" == "$runner_name" ]] \
  || { echo "error: runner group membership drifted" >&2; exit 70; }
stage "all local and GitHub gates passed"
echo "builder handoff complete: runner group and trusted host identity are live"
