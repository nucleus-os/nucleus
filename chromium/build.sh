#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/scripts/chromium-env.sh"

product="${1:-all}"
if [[ $# -gt 0 ]]; then
  shift
fi

prepare_only=0
cef_args=()
for arg in "$@"; do
  case "$arg" in
    --prepare-only)
      prepare_only=1
      ;;
    --force-clean|--no-update|--skip-deps|--install-build-deps)
      cef_args+=("$arg")
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

case "$product" in
  all|cef|browser) ;;
  -h|--help)
    cat <<'EOF'
Usage: chromium/build.sh [all|cef|browser] [options]

Products share one pinned Chromium checkout, depot_tools installation, PGO
profiles, Dawn checkout, and compiler cache. CEF and the Chromium browser use
separate GN output directories because their allocator/process contracts
differ.

Options:
  --prepare-only       Sync and apply the requested product patches without building.
  --force-clean        Recreate the shared Chromium checkout before preparation.
  --no-update          Reuse the current checkout.
  --skip-deps          Reuse the current depot_tools checkout.
  --install-build-deps Run Chromium's host dependency installer.
EOF
    exit 0
    ;;
  *)
    echo "unknown product: $product" >&2
    exit 2
    ;;
esac

build_cef() {
  local args=("${cef_args[@]}")
  if [[ $prepare_only -eq 1 ]]; then
    args+=(--prepare-only)
  fi
  "$workspace_root/cef/build.sh" "${args[@]}"
}

prepare_source() {
  local args=("${cef_args[@]}" --prepare-only)
  "$workspace_root/cef/build.sh" "${args[@]}"
}

build_prepared_cef() {
  "$workspace_root/cef/build.sh" --build-only --skip-deps
}

build_browser() {
  local prepare_source="${1:-1}"
  if [[ "$prepare_source" == 1 ]]; then
    local prepare_args=("${cef_args[@]}")
    prepare_args+=(--prepare-only)
    "$workspace_root/cef/build.sh" "${prepare_args[@]}"
  fi

  if [[ $prepare_only -eq 1 ]]; then
    echo
    echo "== cumulative Chromium source prepared =="
    echo "source: $NUCLEUS_CHROMIUM_SRC_ROOT"
    return
  fi

  export PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH"
  export DEPOT_TOOLS_UPDATE=0
  export CCACHE_DIR

  echo "-- generating Nucleus Browser engine output: $CHROMIUM_BROWSER_OUT"
  (
    cd "$NUCLEUS_CHROMIUM_SRC_ROOT"
    "$NUCLEUS_CHROMIUM_SRC_ROOT/buildtools/linux64/gn" gen \
      "$CHROMIUM_BROWSER_OUT" \
      --args="$CHROMIUM_BROWSER_GN_DEFINES_BASE $CHROMIUM_BROWSER_GN_EXTRA"
  )

  echo "-- building Nucleus Browser engine"
  autoninja -j "$NUCLEUS_CEF_JOBS" -C "$CHROMIUM_BROWSER_OUT" \
    chrome chrome_sandbox

  echo
  echo "== Nucleus Browser engine build complete =="
  echo "binary: $CHROMIUM_BROWSER_OUT/chrome"
  echo "install: $workspace_root/chromium/install-browser.sh"
  echo "diagnose: $workspace_root/chromium/diagnose-browser.sh"
}

case "$product" in
  cef)
    build_cef
    ;;
  browser)
    build_browser
    ;;
  all)
    prepare_source
    if [[ $prepare_only -eq 1 ]]; then
      exit 0
    fi

    if [[ ! "$NUCLEUS_CEF_JOBS" =~ ^[1-9][0-9]*$ ]]; then
      echo "NUCLEUS_CEF_JOBS must be a positive integer: $NUCLEUS_CEF_JOBS" >&2
      exit 2
    fi

    # Source preparation is the only mutating shared stage. Once it completes,
    # the two products generate and build independent GN outputs concurrently.
    # Split the configured CPU budget so two Ninja processes do not each assume
    # they own the whole machine.
    cef_jobs=$((NUCLEUS_CEF_JOBS / 2))
    browser_jobs=$((NUCLEUS_CEF_JOBS - cef_jobs))
    if [[ $cef_jobs -lt 1 ]]; then
      cef_jobs=1
    fi
    if [[ $browser_jobs -lt 1 ]]; then
      browser_jobs=1
    fi

    echo "-- building CEF and Nucleus Browser concurrently"
    echo "   CEF jobs:     $cef_jobs"
    echo "   browser jobs: $browser_jobs"

    (
      NUCLEUS_CEF_JOBS="$cef_jobs" build_prepared_cef
    ) &
    cef_pid=$!
    (
      NUCLEUS_CEF_JOBS="$browser_jobs" build_browser 0
    ) &
    browser_pid=$!

    cef_status=0
    browser_status=0
    for _ in 1 2; do
      completed_pid=
      completed_status=0
      wait -n -p completed_pid || completed_status=$?
      if [[ "$completed_pid" == "$cef_pid" ]]; then
        cef_status=$completed_status
        echo "-- CEF build exited with status $cef_status"
      elif [[ "$completed_pid" == "$browser_pid" ]]; then
        browser_status=$completed_status
        echo "-- Nucleus Browser build exited with status $browser_status"
      else
        echo "parallel Chromium build lost track of child process $completed_pid" >&2
        exit 1
      fi
    done
    if [[ $cef_status -ne 0 || $browser_status -ne 0 ]]; then
      echo "parallel Chromium build failed: CEF=$cef_status browser=$browser_status" >&2
      exit 1
    fi
    ;;
esac
