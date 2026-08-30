#!/usr/bin/env bash
# Workspace-owned Collider launcher. The installed `collider` shim delegates
# here so launcher behavior always comes from the active checkout.
set -euo pipefail

root="${NUCLEUS_WORKSPACE_ROOT:-}"
if [[ -z "$root" || ! -f "$root/collider/Package.swift" ]]; then
  dir="$PWD"
  root=""
  while [[ "$dir" != / ]]; do
    if [[ -f "$dir/collider-setup.sh" && -f "$dir/collider/Package.swift" ]]; then
      root="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
fi
if [[ -z "$root" ]]; then
  echo "collider: not inside a Nucleus workspace (no clone at or above $PWD)" >&2
  exit 1
fi

export NUCLEUS_WORKSPACE_ROOT="$root"
host_env="$root/tools/host-env.sh"
# Report why, not merely that. The host environment fails for reasons that are
# specific and actionable — a missing toolchain, an unreadable source graph, a
# repository another account owns — and a generic message sends every one of
# them to the same wrong remedy.
if ! host_env_error="$( ( source "$host_env" ) 2>&1 >/dev/null )"; then
  echo "collider: the host build environment is unavailable" >&2
  if [[ -n "$host_env_error" ]]; then
    while IFS= read -r host_env_line; do
      echo "collider:   $host_env_line" >&2
    done <<<"$host_env_error"
  fi
  echo "collider: if the toolchain itself is absent, run $root/collider-setup.sh" >&2
  exit 1
fi
source "$host_env"

pkg="$root/collider"
if [[ "$(uname -s)" == Darwin ]]; then
  application_support_root="$HOME/Library/Application Support/Nucleus/Collider"
  cache_root="$HOME/Library/Caches/Nucleus/Collider"
  developer_root="$HOME/Library/Developer/Nucleus/Collider"
else
  application_support_root="${XDG_CONFIG_HOME:-$HOME/.config}/nucleus/collider"
  cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/collider"
  developer_root="${XDG_STATE_HOME:-$HOME/.local/state}/nucleus/collider"
fi
swiftpm_security_root="$application_support_root/swiftpm/security"
swiftpm_cache_root="$cache_root/swiftpm"
scratch_root="$developer_root/build/collider-cli"
bin="$scratch_root/release/collider"
fingerprint_file="$application_support_root/launcher/collider-release-source.sha256"
mkdir -p \
  "$swiftpm_security_root" \
  "$swiftpm_cache_root" \
  "$scratch_root" \
  "$(dirname "$fingerprint_file")"
hash_standard_input() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

append_repository_state() {
  local repository="$1"
  local label="$2"
  shift 2
  printf 'repository\0%s\0' "$label"
  # Hash the effective tree directly. Encoding index objects plus a working
  # diff represents identical content differently before and after commit;
  # paths, Git modes, and content digests do not. Repository HEAD remains
  # provenance for the checkout as a whole rather than a compiler input.
  # One streaming reader avoids spawning Git once per file. Tracked and
  # untracked paths deliberately share one representation, and missing tracked
  # paths are omitted, so adding or deleting the effective tree and then
  # committing it leaves this byte stream unchanged.
  {
    git -C "$repository" ls-files --cached -z -- "$@"
    git -C "$repository" ls-files --others --exclude-standard -z -- "$@"
  } | /usr/bin/perl -e '
    use strict;
    use warnings;
    my $repository = shift @ARGV;
    local $/ = "\0";
    my %paths;
    while (defined(my $path = <STDIN>)) {
      chop $path;
      $paths{$path} = 1;
    }
    binmode STDOUT;
    for my $path (sort keys %paths) {
      my $full = "$repository/$path";
      my ($mode, $size);
      if (-l $full) {
        my $target = readlink($full);
        defined $target or die "cannot read symlink $full: $!\n";
        $mode = 120000;
        $size = length($target);
        print "file\0$path\0$mode\0$size\0$target";
        next;
      }
      next unless -e $full;
      -f $full or die "unsupported launcher input $full\n";
      $mode = -x $full ? 100755 : 100644;
      $size = -s $full;
      print "file\0$path\0$mode\0$size\0";
      open my $input, "<:raw", $full or die "cannot read $full: $!\n";
      my $buffer;
      while (read($input, $buffer, 1024 * 1024)) { print $buffer; }
      close $input or die "cannot close $full: $!\n";
    }
  ' "$repository"
}

collider_source_fingerprint() {
  local source_repository
  local source_repositories=(
    third-party/container
    third-party/swift-java
  )
  local root_paths=(
    collider/Package.swift
    collider/Package.resolved
    collider/.swiftpm/configuration/mirrors.json
    collider/Sources
    collider/engine/Package.swift
    collider/engine/Package.resolved
    collider/engine/.swiftpm/configuration/mirrors.json
    collider/engine/Sources
    tools/collider-launcher.sh
    tools/host-env.sh
    tools/host-platform-env.sh
  )
  {
    swiftc --version 2>&1
    append_repository_state "$root" . "${root_paths[@]}"
    # These are the root-owned source repositories in Collider's SwiftPM
    # dependency closure. Remote transitive packages remain SwiftPM-owned.
    for source_repository in "${source_repositories[@]}"; do
      append_repository_state "$root/$source_repository" "$source_repository" .
    done
  } | hash_standard_input
}

# Git supplies the committed, modified, staged, and untracked identity of
# Collider's compilation closure. SwiftPM remains the sole builder; the launcher
# only avoids asking it to re-plan a source/toolchain state it has already built.
fingerprint="$(collider_source_fingerprint)"
recorded_fingerprint=""
if [[ -r "$fingerprint_file" ]]; then
  recorded_fingerprint="$(<"$fingerprint_file")"
fi
if [[ ! -x "$bin" || "$fingerprint" != "$recorded_fingerprint" ]]; then
  # Say why the executable is being rebuilt. A refresh costs minutes, and the
  # two reasons call for opposite responses: a missing binary means something
  # removed it, while a moved fingerprint means one of Collider's declared
  # compilation inputs actually changed. Reporting only that a build is
  # happening leaves a reader unable to tell an expected refresh from a second
  # one in the same session.
  if [[ ! -x "$bin" ]]; then
    refresh_reason="no release executable at $bin"
  else
    refresh_reason="source fingerprint changed"
  fi
  refresh_notice="collider: refreshing the release executable ($refresh_reason)"
  # SwiftPM reports planning and construction in thousands of lines that bury
  # whatever the step was asked to do. A group collapses them behind that one
  # sentence, which is why the sentence becomes the group's title rather than a
  # line above it. The group closes on the failure path too: an unterminated
  # group swallows every remaining line of the step, the error included.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::group::$refresh_notice" >&2
  else
    echo "$refresh_notice" >&2
  fi
  refresh_status=0
  swift build \
    --package-path "$pkg" \
    --cache-path "$swiftpm_cache_root" \
    --security-path "$swiftpm_security_root" \
    --scratch-path "$scratch_root" \
    --only-use-versions-from-resolved-file \
    -c release \
    --product collider >&2 || refresh_status=$?
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::endgroup::" >&2
  fi
  if [[ "$refresh_status" -ne 0 ]]; then
    exit "$refresh_status"
  fi
  fingerprint="$(collider_source_fingerprint)"
  temporary_fingerprint="$fingerprint_file.$$"
  printf '%s\n' "$fingerprint" >"$temporary_fingerprint"
  mv -f "$temporary_fingerprint" "$fingerprint_file"
fi

if [[ "${COLLIDER_REFRESH_ONLY:-0}" == 1 ]]; then
  exit 0
fi

export COLLIDER_ENTRYPOINT=workspace-launcher
exec "$bin" "$@"
