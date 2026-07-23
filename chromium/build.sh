#!/usr/bin/env bash
# Workspace Chromium orchestrator. The supported public entry is
# `tools/nucleus chromium doctor|bootstrap|build|test|install`.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/scripts/chromium-env.sh"
source "$script_dir/scripts/build-support.sh"

if [[ "${NUCLEUS_CHROMIUM_CLI:-0}" != 1 ]]; then
  echo "chromium/build.sh is internal; use tools/nucleus chromium" >&2
  exit 2
fi

operation="${1:-}"
if [[ $# -ne 1 || ! "$operation" =~ ^(doctor|bootstrap|build|test|install)$ ]]; then
  cat >&2 <<'EOF'
Usage: tools/nucleus chromium doctor|bootstrap|build|test|install

  doctor     Validate the production Chromium host contract
  bootstrap  Prepare the pinned source generation and install host packages
  build      Prepare, build, validate, and atomically publish CEF + browser
  test       Run metadata, package, CEF, and browser behavioral gates
  install    Atomically install the latest validated browser generation
EOF
  exit 2
fi

nucleus_chromium_export_source_generation
export NUCLEUS_CHROMIUM_ORCHESTRATED=1
nucleus_chromium_start_run "$operation"

on_exit() {
  local status=$?
  nucleus_chromium_stop_active_stage
  nucleus_chromium_finish_run "$status"
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
trap 'nucleus_chromium_signal INT 130' INT
trap 'nucleus_chromium_signal TERM 143' TERM
trap 'nucleus_chromium_signal HUP 129' HUP

case "$operation" in
  doctor)
    nucleus_chromium_run_stage host-preflight "$script_dir/scripts/doctor.sh"
    if [[ -f "$NUCLEUS_CEF_SRC_ROOT/nucleus-source-manifest.json" ]]; then
      nucleus_chromium_run_stage source-verify \
        python3 "$script_dir/scripts/build-metadata.py" verify-source \
          --workspace "$workspace_root" \
          --cef-branch "$NUCLEUS_CEF_BRANCH" \
          --cef-checkout "$NUCLEUS_CEF_CHECKOUT" \
          --chromium-version "$NUCLEUS_CEF_CHROMIUM_VERSION" \
          --chromium-checkout "$NUCLEUS_CHROMIUM_CHECKOUT" \
          --depot-tools-revision "$NUCLEUS_DEPOT_TOOLS_REVISION" \
          --source-root "$NUCLEUS_CEF_SRC_ROOT" \
          --depot-tools "$NUCLEUS_CEF_DEPOT_TOOLS" \
          --manifest "$NUCLEUS_CEF_SRC_ROOT/nucleus-source-manifest.json"
    else
      echo "source generation is not prepared yet: $NUCLEUS_CHROMIUM_SOURCE_ID"
    fi
    ;;
  bootstrap)
    nucleus_chromium_acquire_lock source
    nucleus_chromium_run_stage bootstrap-preflight \
      "$script_dir/scripts/doctor.sh" bootstrap
    nucleus_chromium_run_stage bootstrap "$workspace_root/cef/build.sh" bootstrap
    ;;
  build)
    nucleus_chromium_acquire_lock source
    nucleus_chromium_acquire_lock cef-output
    nucleus_chromium_acquire_lock browser-output
    nucleus_chromium_acquire_lock cef-publication
    nucleus_chromium_acquire_lock browser-publication
    nucleus_chromium_run_stage host-preflight "$script_dir/scripts/doctor.sh"
    nucleus_chromium_run_stage source-prepare "$workspace_root/cef/build.sh" prepare
    # The two official ThinLTO outputs are deliberately sequential. Each output
    # owns an independent Chromium link pool with a 30 GiB Linux ThinLTO budget.
    nucleus_chromium_run_stage cef-build "$workspace_root/cef/build.sh" build
    nucleus_chromium_run_stage cef-package "$workspace_root/cef/build.sh" package
    nucleus_chromium_run_stage cef-validate "$workspace_root/cef/build.sh" validate
    nucleus_chromium_run_stage browser-build "$script_dir/product.sh" build
    nucleus_chromium_run_stage browser-package "$script_dir/product.sh" package
    nucleus_chromium_run_stage browser-validate "$script_dir/product.sh" validate
    nucleus_chromium_run_stage cache-retention \
      python3 "$script_dir/scripts/prune-cache.py" cache \
        --cache-root "$NUCLEUS_CEF_CACHE_ROOT" \
        --source-generations "$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS" \
        --source-current "$NUCLEUS_CHROMIUM_SOURCE_CURRENT" \
        --cef-dist "$NUCLEUS_CEF_DIST_ROOT" \
        --browser-dist "$NUCLEUS_BROWSER_DIST_ROOT" \
        --logs "$NUCLEUS_CEF_LOG_DIR"
    nucleus_chromium_record_storage
    ;;
  test)
    nucleus_chromium_acquire_lock cef-output
    nucleus_chromium_acquire_lock browser-output
    nucleus_chromium_run_stage host-preflight "$script_dir/scripts/doctor.sh"
    nucleus_chromium_run_stage metadata-tests \
      python3 "$script_dir/scripts/build-metadata-test.py"
    nucleus_chromium_run_stage cache-retention-tests \
      python3 "$script_dir/scripts/prune-cache-test.py"
    nucleus_chromium_run_stage atomic-publication-tests \
      python3 "$workspace_root/cef/scripts/atomic-publish-directory-test.py"
    nucleus_chromium_run_stage cef-validate "$workspace_root/cef/build.sh" validate
    nucleus_chromium_run_stage browser-tests "$script_dir/product.sh" test
    nucleus_chromium_record_storage
    ;;
  install)
    nucleus_chromium_acquire_lock browser-publication
    nucleus_chromium_run_stage browser-preinstall-validate "$script_dir/product.sh" validate
    nucleus_chromium_run_stage browser-install "$script_dir/install-browser.sh"
    ;;
esac

echo
echo "Chromium $operation completed"
