#!/usr/bin/env bash

# Shared orchestration primitives. Product scripts are intentionally internal;
# chromium/build.sh is the only owner of locks, logs, host preflight, and stage
# lifetime.

nucleus_chromium_source_id() {
  python3 "$workspace_root/chromium/scripts/build-metadata.py" source-id \
    --workspace "$workspace_root" \
    --cef-branch "$NUCLEUS_CEF_BRANCH" \
    --cef-checkout "$NUCLEUS_CEF_CHECKOUT" \
    --chromium-version "$NUCLEUS_CEF_CHROMIUM_VERSION" \
    --chromium-checkout "$NUCLEUS_CHROMIUM_CHECKOUT" \
    --depot-tools-revision "$NUCLEUS_DEPOT_TOOLS_REVISION"
}

nucleus_chromium_export_source_generation() {
  export NUCLEUS_CHROMIUM_SOURCE_ID
  NUCLEUS_CHROMIUM_SOURCE_ID="$(nucleus_chromium_source_id)"
  export NUCLEUS_CEF_SRC_ROOT="$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS/$NUCLEUS_CHROMIUM_SOURCE_ID"
  export NUCLEUS_CHROMIUM_SRC_ROOT="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  export CHROMIUM_BROWSER_OUT="$NUCLEUS_CHROMIUM_SRC_ROOT/out/NucleusBrowser_GN_x64"
}

nucleus_chromium_require_command() {
  local command="$1"
  local package="$2"
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "MISSING executable $command (install package: $package)" >&2
    return 1
  fi
  echo "ok      executable $command"
}

nucleus_chromium_preflight() {
  local mode="${1:-build}"
  if [[ ! "$mode" =~ ^(bootstrap|build)$ ]]; then
    echo "invalid Chromium preflight mode: $mode" >&2
    return 2
  fi
  local failures=0
  local command package
  while read -r command package; do
    nucleus_chromium_require_command "$command" "$package" || failures=$((failures + 1))
  done <<'EOF'
git git
python3 python3
curl curl
tar tar
sha256sum coreutils
flock util-linux
setsid util-linux
timeout coreutils
EOF
  if [[ "$mode" == build ]]; then
    while read -r command package; do
      nucleus_chromium_require_command "$command" "$package" || failures=$((failures + 1))
    done <<'EOF'
readelf binutils
ldd libc-bin
cc build-essential
EOF
  else
    while read -r command package; do
      nucleus_chromium_require_command "$command" "$package" || failures=$((failures + 1))
    done <<'EOF'
sudo sudo
apt-get apt
EOF
  fi
  local memory_total swap_total available_bytes available_inodes map_count
  memory_total="$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)"
  swap_total="$(awk '/^SwapTotal:/ {print $2 * 1024}' /proc/meminfo)"
  map_count="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  local disk_probe="$NUCLEUS_CEF_CACHE_ROOT"
  if [[ ! -e "$disk_probe" ]]; then
    disk_probe="$(dirname -- "$disk_probe")"
  fi
  while [[ ! -e "$disk_probe" && "$disk_probe" != / ]]; do
    disk_probe="$(dirname -- "$disk_probe")"
  done
  available_bytes="$(df -B1 --output=avail "$disk_probe" | tail -1 | tr -d ' ')"
  available_inodes="$(df --output=iavail "$disk_probe" | tail -1 | tr -d ' ')"

  local gib=$((1024 * 1024 * 1024))
  echo "ok      physical memory $((memory_total / gib)) GiB"
  if [[ "$mode" == build ]]; then
    if (( swap_total < 32 * gib )); then
      echo "MISSING at least 32 GiB swap; found $((swap_total / gib)) GiB" >&2
      failures=$((failures + 1))
    else
      echo "ok      swap $((swap_total / gib)) GiB"
    fi
  else
    echo "info    swap $((swap_total / gib)) GiB (32 GiB required before build/test)"
  fi
  if (( available_bytes < 120 * gib )); then
    echo "MISSING at least 120 GiB free under $disk_probe; found $((available_bytes / gib)) GiB" >&2
    failures=$((failures + 1))
  else
    echo "ok      free disk $((available_bytes / gib)) GiB"
  fi
  if (( available_inodes < 1000000 )); then
    echo "MISSING at least 1000000 free inodes under $disk_probe; found $available_inodes" >&2
    failures=$((failures + 1))
  else
    echo "ok      free inodes $available_inodes"
  fi
  if [[ "$mode" == build ]]; then
    if (( map_count < 262144 )); then
      echo "MISSING vm.max_map_count >= 262144; found $map_count" >&2
      failures=$((failures + 1))
    else
      echo "ok      vm.max_map_count $map_count"
    fi
  else
    echo "info    vm.max_map_count $map_count (262144 required before build/test)"
  fi
  if (( failures != 0 )); then
    echo "Chromium doctor found $failures prerequisite violation(s)" >&2
    return 1
  fi
  echo "Chromium $mode host contract satisfied"
}

NUCLEUS_CHROMIUM_LOCK_FDS=()
nucleus_chromium_acquire_lock() {
  local name="$1"
  local lock_dir="$NUCLEUS_CEF_CACHE_ROOT/locks"
  mkdir -p -- "$lock_dir"
  local descriptor
  exec {descriptor}>"$lock_dir/$name.lock"
  if ! flock -n "$descriptor"; then
    echo "Chromium workflow lock is already held: $name" >&2
    exit 1
  fi
  NUCLEUS_CHROMIUM_LOCK_FDS+=("$descriptor")
}

nucleus_chromium_start_run() {
  local operation="$1"
  local timestamp run_name latest_temporary
  timestamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
  run_name="$timestamp-$$-$operation"
  export NUCLEUS_CHROMIUM_RUN_DIR="$NUCLEUS_CEF_LOG_DIR/runs/$run_name"
  mkdir -p -- "$NUCLEUS_CHROMIUM_RUN_DIR"
  latest_temporary="$NUCLEUS_CEF_LOG_DIR/.latest.$$"
  ln -s -- "runs/$run_name" "$latest_temporary"
  mv -Tf -- "$latest_temporary" "$NUCLEUS_CEF_LOG_DIR/latest"
  export NUCLEUS_CHROMIUM_RUN_LOG="$NUCLEUS_CHROMIUM_RUN_DIR/run.log"
  exec > >(trap '' INT TERM; exec tee -a -- "$NUCLEUS_CHROMIUM_RUN_LOG") 2>&1

  python3 - "$NUCLEUS_CHROMIUM_RUN_DIR/manifest.json" "$operation" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, operation = sys.argv[1:]
keys = [
    "NUCLEUS_CEF_BRANCH",
    "NUCLEUS_CEF_CHECKOUT",
    "NUCLEUS_CEF_CHROMIUM_VERSION",
    "NUCLEUS_CHROMIUM_CHECKOUT",
    "NUCLEUS_DEPOT_TOOLS_REVISION",
    "NUCLEUS_CHROMIUM_SOURCE_ID",
    "NUCLEUS_CEF_SRC_ROOT",
    "NUCLEUS_CHROMIUM_SRC_ROOT",
    "CHROMIUM_BROWSER_OUT",
    "NUCLEUS_CEF_DEPOT_TOOLS",
    "NUCLEUS_CEF_DIST_ROOT",
    "NUCLEUS_BROWSER_DIST_ROOT",
    "NUCLEUS_CHROMIUM_JOBS",
]
manifest = {
    "schema": 1,
    "operation": operation,
    "started_at": datetime.now(timezone.utc).isoformat(),
    "status": "running",
    "inputs": {key: os.environ.get(key) for key in keys},
}
with open(path, "w", encoding="utf-8") as destination:
    json.dump(manifest, destination, indent=2, sort_keys=True)
    destination.write("\n")
PY
  echo "Chromium run: $NUCLEUS_CHROMIUM_RUN_DIR"
}

nucleus_chromium_record_storage() {
  local destination="$NUCLEUS_CHROMIUM_RUN_DIR/storage.log"
  {
    df -h "$NUCLEUS_CEF_CACHE_ROOT"
    df -i "$NUCLEUS_CEF_CACHE_ROOT"
    local storage_path
    for storage_path in \
      "$NUCLEUS_CEF_SRC_ROOT" \
      "$NUCLEUS_CHROMIUM_SRC_ROOT/out/Release_GN_x64/thinlto-cache" \
      "$CHROMIUM_BROWSER_OUT/thinlto-cache" \
      "$NUCLEUS_CEF_DIST_ROOT" \
      "$NUCLEUS_BROWSER_DIST_ROOT"; do
      if [[ -e "$storage_path" ]]; then
        du -sh "$storage_path"
      fi
    done
  } | tee "$destination"
}

NUCLEUS_CHROMIUM_ACTIVE_PID=""
nucleus_chromium_stop_active_stage() {
  if [[ -n "$NUCLEUS_CHROMIUM_ACTIVE_PID" ]]; then
    kill -TERM -- "-$NUCLEUS_CHROMIUM_ACTIVE_PID" 2>/dev/null || true
    wait "$NUCLEUS_CHROMIUM_ACTIVE_PID" 2>/dev/null || true
    NUCLEUS_CHROMIUM_ACTIVE_PID=""
  fi
}

nucleus_chromium_run_stage() {
  local name="$1"
  shift
  local log="$NUCLEUS_CHROMIUM_RUN_DIR/$name.log"
  echo
  echo "==> $name"
  setsid "$@" \
    > >(trap '' INT TERM; exec tee -a -- "$log") 2>&1 &
  NUCLEUS_CHROMIUM_ACTIVE_PID=$!
  local status=0
  wait "$NUCLEUS_CHROMIUM_ACTIVE_PID" || status=$?
  NUCLEUS_CHROMIUM_ACTIVE_PID=""
  if (( status != 0 )); then
    echo "stage failed: $name (exit $status)" >&2
    return "$status"
  fi
}

nucleus_chromium_finish_run() {
  local status="$1"
  if [[ -z "${NUCLEUS_CHROMIUM_RUN_DIR:-}" || ! -f "$NUCLEUS_CHROMIUM_RUN_DIR/manifest.json" ]]; then
    return
  fi
  python3 - "$NUCLEUS_CHROMIUM_RUN_DIR/manifest.json" "$status" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, status = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    manifest = json.load(source)
manifest["finished_at"] = datetime.now(timezone.utc).isoformat()
manifest["status"] = "succeeded" if status == "0" else "failed"
manifest["exit_status"] = int(status)
temporary = path + f".{os.getpid()}.tmp"
with open(temporary, "w", encoding="utf-8") as destination:
    json.dump(manifest, destination, indent=2, sort_keys=True)
    destination.write("\n")
os.replace(temporary, path)
PY
}

nucleus_chromium_signal() {
  local signal="$1"
  local status="$2"
  nucleus_chromium_stop_active_stage
  nucleus_chromium_finish_run "$status"
  trap - EXIT
  exit "$status"
}
