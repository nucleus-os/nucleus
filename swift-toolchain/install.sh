#!/usr/bin/env bash
# Install the built Swift toolchain to /opt/nucleus-swift/<version>/ and
# wire /etc/profile.d/nucleus-swift.sh so a fresh login shell finds
# `swift` on PATH.
#
# Usage:
#   sudo ./install.sh               # install (or upgrade) the toolchain
#   sudo ./install.sh --uninstall   # remove everything this script writes
#   ./install.sh --help             # print this message
#
# Layout:
#   /opt/nucleus-swift/release-6.4.x/usr/    # the toolchain
#   /opt/nucleus-swift/current -> release-6.4.x   # version selector
#   /etc/profile.d/nucleus-swift.sh          # PATH wiring
#
# The install is transactional: the candidate is validated before publication
# and the previous tree remains available for rollback until the replacement
# runs successfully through the live selector.
#
# Override via env:
#   NUCLEUS_SWIFT_VERSION   default: release-6.4.x
#   NUCLEUS_SWIFT_PREFIX    default: /opt/nucleus-swift
#   NUCLEUS_SWIFT_TARBALL   default: $cache/swift-<version>-linux.tar.gz
#                                    (where $cache is the invoking
#                                     user's nucleus build cache)

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="${NUCLEUS_SWIFT_VERSION:-release-6.4.x}"
prefix="${NUCLEUS_SWIFT_PREFIX:-/opt/nucleus-swift}"

mode=install
for arg in "$@"; do
  case "$arg" in
    --uninstall) mode=uninstall ;;
    --help|-h)
      # Print the leading comment block (lines 2..first non-comment).
      awk 'NR==1 { next }
           /^# / { sub(/^# /, ""); print; next }
           /^#$/ { print ""; next }
           { exit }' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "Must be run as root: sudo $0 $*" >&2
    exit 1
  fi
}

resolve_tarball() {
  if [[ -n "${NUCLEUS_SWIFT_TARBALL:-}" ]]; then
    echo "$NUCLEUS_SWIFT_TARBALL"
    return
  fi
  local user_home="${HOME}"
  if [[ -n "${SUDO_USER:-}" ]]; then
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  fi
  echo "$user_home/.cache/nucleus/swift-toolchains/$version/swift-${version}-linux.tar.gz"
}

uninstall() {
  require_root "$@"
  echo "Removing /etc/profile.d/nucleus-swift.sh"
  rm -f /etc/profile.d/nucleus-swift.sh
  echo "Removing $prefix/$version/"
  rm -rf "$prefix/$version"
  if [[ -L "$prefix/current" ]]; then
    local current_target
    current_target=$(readlink "$prefix/current")
    if [[ "$current_target" == "$version" ]]; then
      echo "Removing $prefix/current -> $current_target"
      rm -f "$prefix/current"
    fi
  fi
  rmdir "$prefix" 2>/dev/null || true
  echo ""
  echo "Uninstalled."
  echo "(Build artifacts in your home cache at \$HOME/.cache/nucleus/"
  echo " were not touched.)"
}

# Validate that static host-tool link metadata was packaged by Collider. The
# installer never repairs or augments artifacts.
require_static_stdlib_args() {
  local usr="$1"
  local lnk="$usr/lib/swift_static/linux/static-stdlib-args.lnk"
  if [[ ! -f "$lnk" ]]; then
    echo "Toolchain artifact is incomplete: $lnk is missing" >&2
    return 1
  fi
  local required
  for required in -lswift_StringProcessing -l_CFXMLInterface -lxml2; do
    if ! grep -qF -- "$required" "$lnk"; then
      echo "Toolchain artifact has incomplete static link metadata: $required is missing from $lnk" >&2
      echo "Rebuild swift-toolchain and install the new tarball." >&2
      return 1
    fi
  done
}

# Reject stale or incomplete artifacts instead of making the installed tree
# differ from the tarball. A successful new build owns the complete layout;
# install.sh only validates and transactionally replaces the prior installation.
require_foundation_xml_support() {
  local usr="$1"
  local archive
  for archive in \
    "$usr/lib/swift/linux/lib_CFXMLInterface.a" \
    "$usr/lib/swift_static/linux/lib_CFXMLInterface.a"; do
    if [[ ! -f "$archive" ]]; then
      echo "Toolchain artifact is incomplete: $archive is missing" >&2
      echo "Rebuild swift-toolchain and install the new tarball." >&2
      return 1
    fi
  done
}

install() {
  require_root "$@"

  local tarball
  tarball=$(resolve_tarball)
  if [[ ! -f "$tarball" ]]; then
    echo "Tarball not found at: $tarball" >&2
    echo "" >&2
    echo "Build it first:" >&2
    echo "  tools/collider toolchain rebuild" >&2
    echo "or set NUCLEUS_SWIFT_TARBALL=/path/to/tarball.tar.gz" >&2
    exit 1
  fi

  echo "Installing nucleus-swift $version"
  echo "  from: $tarball"
  echo "  to:   $prefix/$version/usr/"
  echo ""

  mkdir -p "$prefix"

  # Stage the tarball outside the live tree before publication.
  # `staging` is intentionally a *global* so the EXIT trap (registered
  # outside this function) can see it.
  staging=$(mktemp -d "$prefix/.stage-XXXXXX")

  echo "Extracting..."
  tar -x -z -f "$tarball" -C "$staging"
  if [[ ! -d "$staging/usr" ]]; then
    echo "Tarball did not contain expected 'usr/' top-level dir" >&2
    exit 1
  fi

  require_static_stdlib_args "$staging/usr"
  require_foundation_xml_support "$staging/usr"


  # Prepare and execute the candidate before changing the live installation.
  # An artifact that cannot run from its extracted layout never reaches the
  # versioned path.
  chown -R root:root "$staging/usr"
  find "$staging/usr" -type d -exec chmod 0755 {} +
  find "$staging/usr" -type f -not -perm -100 -exec chmod 0644 {} + 2>/dev/null || true
  echo "Verifying staged toolchain..."
  if ! "$staging/usr/bin/swift" --version >/dev/null 2>&1; then
    echo "Verification failed: staged usr/bin/swift did not run" >&2
    exit 1
  fi

  # Prepare ancillary system state before publication. It is atomically
  # installed only after the replacement toolchain runs through `current`.
  profile_candidate="/etc/profile.d/.nucleus-swift.sh.$$"
  cat > "$profile_candidate" <<'EOF'
# Nucleus Swift toolchain — installed by swift-toolchain/install.sh.
# Prepends the toolchain's bin/ to PATH for login shells.
if [ -x /opt/nucleus-swift/current/usr/bin/swift ]; then
  case ":$PATH:" in
    *:/opt/nucleus-swift/current/usr/bin:*) ;;
    *) PATH="/opt/nucleus-swift/current/usr/bin:$PATH" ;;
  esac
  export PATH
fi
EOF
  chmod 0644 "$profile_candidate"

  # Keep the previous tree until all installation work and live verification
  # succeed. The EXIT trap restores it if anything after this point fails.
  local target="$prefix/$version"
  mkdir -p "$target"
  replacement_target="$target/usr"
  replacement_backup="$target/.usr.replaced.$$"
  if [[ -e "$replacement_backup" || -L "$replacement_backup" ]]; then
    echo "Refusing to overwrite unexpected rollback path: $replacement_backup" >&2
    exit 1
  fi
  if [[ -e "$replacement_target" || -L "$replacement_target" ]]; then
    mv "$replacement_target" "$replacement_backup"
    replacement_had_previous=1
  fi
  replacement_started=1
  mv "$staging/usr" "$replacement_target"

  # Publish the selector through an atomic sibling rename.
  if [[ -e "$prefix/current" && ! -L "$prefix/current" ]]; then
    echo "Refusing to replace non-symlink path: $prefix/current" >&2
    exit 1
  fi
  if [[ -L "$prefix/current" ]]; then
    previous_current=$(readlink "$prefix/current")
    current_had_previous=1
  fi
  current_candidate="$prefix/.current.$$"
  rm -f -- "$current_candidate"
  ln -s "$version" "$current_candidate"
  mv -Tf -- "$current_candidate" "$prefix/current"
  current_candidate=""
  current_swapped=1

  # Verify the install runs end-to-end before declaring success.
  echo ""
  echo "Verifying..."
  if ! "$prefix/current/usr/bin/swift" --version >/dev/null 2>&1; then
    echo "Verification failed: $prefix/current/usr/bin/swift did not run" >&2
    exit 1
  fi
  "$prefix/current/usr/bin/swift" --version

  mv -Tf -- "$profile_candidate" /etc/profile.d/nucleus-swift.sh
  profile_candidate=""
  replacement_started=0
  if [[ -n "$replacement_backup" ]] && ! rm -rf -- "$replacement_backup"; then
    echo "warning: replacement succeeded but rollback cleanup failed: $replacement_backup" >&2
  else
    replacement_backup=""
  fi

  echo ""
  echo "Installed."
  echo ""
  echo "  Toolchain:   $prefix/$version/usr/"
  echo "  Current:     $prefix/current -> $version"
  echo "  PATH wiring: /etc/profile.d/nucleus-swift.sh"
  echo ""
  echo "Take effect for the current shell with:"
  echo "  source /etc/profile.d/nucleus-swift.sh"
  echo ""
  echo "New login shells pick it up automatically."
}

# Cleanup and rollback state is global so the EXIT trap can restore the prior
# live tree after any failure that occurs during publication.
staging=""
replacement_target=""
replacement_backup=""
replacement_started=0
replacement_had_previous=0
previous_current=""
current_had_previous=0
current_swapped=0
current_candidate=""
profile_candidate=""
cleanup_install() {
  local status=$?
  trap - EXIT

  if (( status != 0 && replacement_started )); then
    rm -rf -- "$replacement_target"
    if (( replacement_had_previous )) && [[ -e "$replacement_backup" || -L "$replacement_backup" ]]; then
      mv "$replacement_backup" "$replacement_target"
    fi
    if (( current_swapped )); then
      if (( current_had_previous )); then
        local rollback_current="$prefix/.current.rollback.$$"
        ln -s "$previous_current" "$rollback_current"
        mv -Tf -- "$rollback_current" "$prefix/current"
      else
        rm -f -- "$prefix/current"
      fi
    fi
  fi

  if [[ -n "${staging:-}" && -d "$staging" ]]; then
    rm -rf "$staging"
  fi
  if [[ -n "${current_candidate:-}" ]]; then
    rm -f -- "$current_candidate"
  fi
  if [[ -n "${profile_candidate:-}" ]]; then
    rm -f -- "$profile_candidate"
  fi
  exit "$status"
}
trap cleanup_install EXIT

case "$mode" in
  install) install "$@" ;;
  uninstall) uninstall "$@" ;;
esac
