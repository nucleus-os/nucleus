#!/bin/bash

# Reading and comparing Actions runner versions, shared by the scripts that
# verify the host and the script that updates it.
#
# Two versions drift independently and are repaired by different acts. The
# installed runner may fall behind the pinned contract, which an operator fixes
# by installing on this host; the pinned contract may fall behind upstream,
# which is a source change and a commit. A single "out of date" answer would
# hide which one is meant, and the two are not interchangeable: the contract
# describes what this host should have, so installing is what makes the host
# match the repository rather than the other way around.

# The release version of an installed runner, without executing it.
#
# `Runner.Listener --version` is authoritative but writes a diagnostic log as it
# starts, so it needs the builder's own privileges and cannot answer a question
# asked from anywhere else. The dependency manifest records the same version and
# is world readable, which is what lets an unprivileged check exist at all.
# Its locals are prefixed because a local that shadows a caller's readonly
# global is refused outright, and the function would then read the caller's
# value instead of its own argument.
nucleus_installed_runner_version() {
  local nucleus_runner_root="$1"
  local nucleus_runner_manifest
  local nucleus_runner_version
  nucleus_runner_manifest="$nucleus_runner_root/bin/Runner.Listener.deps.json"

  [[ -f "$nucleus_runner_manifest" ]] || return 1
  nucleus_runner_version="$(
    /usr/bin/sed -n 's/.*"Runner\.Listener\/\([0-9][0-9.]*\)".*/\1/p' \
      "$nucleus_runner_manifest" \
      | /usr/bin/head -1
  )"
  [[ -n "$nucleus_runner_version" ]] || return 1
  printf '%s\n' "$nucleus_runner_version"
}

# The newest runner release upstream publishes. Host-side network only: no
# container and no build ever asks this.
nucleus_latest_runner_version() {
  /usr/bin/curl --fail --silent --show-error --location \
    --max-time 20 \
    --header 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/actions/runner/releases/latest \
    | /usr/bin/sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    | /usr/bin/head -1
}
