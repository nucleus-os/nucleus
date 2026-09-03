#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME"

target_runtime() {
  local architecture="$1"
  local sysroot_arch triple loader_name
  case "$architecture" in
    arm64)
      sysroot_arch="arm64"
      triple="aarch64-linux-gnu"
      loader_name="ld-linux-aarch64.so.1"
      ;;
    x86_64)
      sysroot_arch="amd64"
      triple="x86_64-linux-gnu"
      loader_name="ld-linux-x86-64.so.2"
      ;;
    *)
      echo "error: unsupported Chromium Linux architecture: $architecture" >&2
      return 64
      ;;
  esac

  local sysroot
  sysroot="$(find /source/chromium/src/build/linux -maxdepth 1 -type d \
    -name "*_${sysroot_arch}-sysroot" -print -quit)"
  if [[ -z "$sysroot" ]]; then
    echo "error: Chromium $architecture sysroot is unavailable" >&2
    return 1
  fi

  local loader
  loader="$(find "$sysroot" \( -type f -o -type l \) \
    -name "$loader_name" -print -quit)"
  if [[ -z "$loader" ]]; then
    echo "error: Chromium $architecture runtime loader is unavailable" >&2
    return 1
  fi

  printf '%s\n%s\n%s\n' "$sysroot" "$triple" "$loader"
}

runtime_library_path() {
  local sysroot="$1"
  local artifact_directory="$2"
  local path="$artifact_directory"
  local directory
  while IFS= read -r directory; do
    path+="${path:+:}$directory"
  done < <(find "$sysroot/lib" "$sysroot/usr/lib" -type d -print)
  printf '%s\n' "$path"
}

case "${1:-}" in
  materialize-source)
    if [[ $# -ne 2 \
        || ! "$2" =~ ^[0-9a-f]{24}$ \
        || ! -f /host-source/source-provenance.json \
        || ! -w /source ]]; then
      echo "error: materialize-source requires an immutable host source and writable workspace" >&2
      exit 64
    fi
    source_id="$2"
    marker=/source/.nucleus-source-id
    if [[ -f "$marker" ]] \
        && [[ "$(<"$marker")" == "$source_id" ]] \
        && [[ ! -e /source/chromium/src/cef/.git/objects/info/alternates ]]; then
      exit 0
    fi
    find /source -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    tar -C /host-source -cf - \
      chromium linux-sysroot-archives source-provenance.json \
      | tar -C /source --no-same-owner -xf -
    archive_root=/source/linux-sysroot-archives
    for archive in "$archive_root"/*.tar.xz; do
      [[ -f "$archive" ]] || continue
      sysroot="${archive%.tar.xz}"
      sysroot="/source/chromium/src/build/linux/${sysroot##*/}"
      stamp="$archive_root/${sysroot##*/}.stamp"
      [[ -f "$stamp" ]] || {
        echo "error: Chromium sysroot archive has no stamp: $archive" >&2
        exit 1
      }
      rm -rf "$sysroot"
      mkdir -p "$sysroot"
      tar mxf "$archive" -C "$sysroot"
      cp "$stamp" "$sysroot/.stamp"
    done
    printf '%s\n' "$source_id" > /source/.nucleus-source-id.preparing
    mv /source/.nucleus-source-id.preparing "$marker"
    exit 0
    ;;
  run-test)
    if [[ $# -lt 2 ]]; then
      echo "error: run-test requires an executable under /build" >&2
      exit 64
    fi
    executable="$2"
    shift 2
    case "${executable}" in
      /build/*) ;;
      *) echo "error: Chromium test executable must be under /build" >&2; exit 64 ;;
    esac
    exec "${executable}" "$@"
    ;;
esac

if [[ ! -f /source/source-provenance.json \
    || ! -x /source/chromium/src/buildtools/linux64/gn \
    || ! -x /source/chromium/src/third_party/siso/cipd/siso ]]; then
  echo "error: Chromium source must contain the complete Linux host-tool closure" >&2
  exit 64
fi
if [[ ! -d /build || ! -w /build ]]; then
  echo "error: /build must be the writable product output" >&2
  exit 64
fi

configure_build() {
  local source_id="$1"
  local gn_arguments="$2"
  local marker=/build/.nucleus-gn-configuration
  local desired="$marker.desired.$$"
  trap 'rm -f "$desired"' EXIT
  printf '%s\n%s\n' "$source_id" "$gn_arguments" >"$desired"
  if [[ -f /build/build.ninja && -f "$marker" ]] \
      && cmp -s "$desired" "$marker"; then
    rm -f "$desired"
    trap - EXIT
    return
  fi
  /source/chromium/src/buildtools/linux64/gn \
    gen /build \
    "--args=$gn_arguments"
  mv -f "$desired" "$marker"
  trap - EXIT
}

case "${1:-}" in
  build)
    if [[ $# -lt 5 || ! "$2" =~ ^[0-9a-f]{24}$ \
        || ! "$4" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: build requires the source identity, GN arguments," \
        "positive job count, and at least one target" >&2
      exit 64
    fi
    source_id="$2"
    gn_arguments="$3"
    jobs="$4"
    shift 4
    configure_build "$source_id" "$gn_arguments"
    # Counters are cumulative and persist in the cache, so zeroing here makes
    # the report below describe this build rather than every build since the
    # workspace was created.
    ccache -z >/dev/null 2>&1 || true
    status=0
    /source/chromium/src/third_party/siso/cipd/siso \
      ninja --offline -local_jobs="$jobs" -C /build "$@" || status=$?
    # Say what the cache did. Without this there is no signal at all: a cache
    # storing nothing looks exactly like one that is working, and this one held
    # 68 MiB of a 30 GiB allowance for months while every compilation missed
    # it. `Could not use modules` is the count clang modules made uncacheable,
    # which is the specific failure that hid here.
    echo "compiler cache after this build:"
    # The settings, not just the counters. A build that compiles nothing
    # reports no counters at all, so the configuration is the only evidence
    # available on such a run -- and configuration is what was wrong twice:
    # once because `-fmodules` needs depend mode and modules sloppiness to be
    # cacheable, and once because none of it was reaching the process.
    ccache --show-config 2>/dev/null \
      | grep -E "^\((environment|.*ccache\.conf)\) (depend_mode|sloppiness|max_size|compiler_check|cache_dir) " \
      || echo "  configuration unavailable"
    ccache -s -v 2>/dev/null || ccache -s 2>/dev/null \
      || echo "  no statistics available"
    exit "$status"
    ;;
  test-ozone)
    if [[ $# -ne 3 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: test-ozone requires a positive job count and architecture" >&2
      exit 64
    fi
    /source/chromium/src/third_party/siso/cipd/siso \
      ninja --offline -local_jobs="$2" -C /build \
      ui/ozone:ozone_unittests \
      components/viz/service:output_presenter_ozone_unittests
    runtime_output="$(target_runtime "$3")"
    mapfile -t runtime <<<"$runtime_output"
    sysroot="${runtime[0]}"
    loader="${runtime[2]}"
    library_path="$(runtime_library_path "$sysroot" /build)"
    "$loader" --library-path "$library_path" /build/ozone_unittests \
      '--gtest_filter=*OzonePresenter*' \
      --single-process-tests
    exec "$loader" --library-path "$library_path" \
      /build/output_presenter_ozone_unittests \
      '--gtest_filter=OutputPresenterOzoneTest.*' \
      --single-process-tests
    ;;
  *)
    echo "error: expected Chromium build command" >&2
    exit 64
    ;;
esac
