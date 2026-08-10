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
    if [[ -f "$marker" ]] && [[ "$(<"$marker")" == "$source_id" ]]; then
      exit 0
    fi
    find /source -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    tar -C /host-source -cf - chromium source-provenance.json \
      | tar -C /source --no-same-owner -xf -
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
  clang-version)
    if [[ $# -ne 1 \
        || ! -x /source/chromium/src/third_party/llvm-build/Linux_x64/bin/clang ]]; then
      echo "error: clang-version requires the Chromium compiler" >&2
      exit 64
    fi
    exec /source/chromium/src/third_party/llvm-build/Linux_x64/bin/clang --version
    ;;
  validate-browser)
    if [[ $# -ne 2 \
        || ! -x /artifact/runtime/nucleus-browser-bin \
        || ! -f /artifact/bin/nucleus-browser \
        || ! -d /source/chromium/src ]]; then
      echo "error: validate-browser requires an architecture, source, and artifact" >&2
      exit 64
    fi
    runtime_output="$(target_runtime "$2")"
    mapfile -t runtime <<<"$runtime_output"
    sysroot="${runtime[0]}"
    loader="${runtime[2]}"
    library_path="$(runtime_library_path "$sysroot" /artifact/runtime)"
    linkage="$("$loader" --library-path "$library_path" \
      --list /artifact/runtime/nucleus-browser-bin)"
    printf '%s\n' "$linkage"
    if grep -Fq 'not found' <<<"$linkage"; then
      exit 1
    fi
    bash -n /artifact/bin/nucleus-browser
    exec "$loader" --library-path "$library_path" \
      /artifact/runtime/nucleus-browser-bin --version
    ;;
  cef-make-distrib)
    if [[ $# -ne 2 \
        || ( "$2" != "--arm64-build" && "$2" != "--x64-build" ) \
        || ! -f /source/chromium/src/cef/tools/make_distrib.py \
        || ! -d /build \
        || ! -w /distribution ]]; then
      echo "error: cef-make-distrib requires source, build, and distribution mounts" >&2
      exit 64
    fi
    exec python3 /source/chromium/src/cef/tools/make_distrib.py \
      --output-dir=/distribution \
      --allow-partial \
      --ninja-build \
      --release-build-dir=/build \
      "$2" \
      --minimal \
      --no-archive
    ;;
  browser-stage)
    if [[ $# -ne 1 || ! -d /build || ! -w /candidate ]]; then
      echo "error: browser-stage requires build and candidate mounts" >&2
      exit 64
    fi
    mkdir -p /candidate/runtime
    for name in \
      chrome chrome_crashpad_handler chrome_sandbox icudtl.dat resources.pak \
      chrome_100_percent.pak chrome_200_percent.pak libEGL.so libGLESv2.so \
      libvulkan.so.1; do
      cp -a "/build/$name" "/candidate/runtime/$name"
    done
    if [[ -f /build/v8_context_snapshot.bin ]]; then
      cp -a /build/v8_context_snapshot.bin /candidate/runtime/
    else
      cp -a /build/snapshot_blob.bin /candidate/runtime/
    fi
    for name in chrome_management_service locales default_apps MEIPreload \
      PrivacySandboxAttestationsPreloaded; do
      if [[ -e "/build/$name" ]]; then
        cp -a "/build/$name" /candidate/runtime/
      fi
    done
    exit 0
    ;;
  validate-cef)
    if [[ $# -ne 2 \
        || ! -f /sdk/Release/libcef.so \
        || ! -f /sdk/include/cef_version_info.h \
        || ! -w /smoke \
        || ! -d /source/chromium/src ]]; then
      echo "error: validate-cef requires an architecture, source, SDK, and scratch mounts" >&2
      exit 64
    fi
    runtime_output="$(target_runtime "$2")"
    mapfile -t runtime <<<"$runtime_output"
    sysroot="${runtime[0]}"
    triple="${runtime[1]}"
    loader="${runtime[2]}"
    library_path="$(runtime_library_path "$sysroot" /sdk/Release)"
    linkage="$("$loader" --library-path "$library_path" --list /sdk/Release/libcef.so)"
    printf '%s\n' "$linkage"
    if grep -Fq 'not found' <<<"$linkage"; then
      exit 1
    fi
    cat > /smoke/consumer.c <<'EOF'
#include "include/cef_version_info.h"
int main(void) { return cef_version_info(0) > 0 ? 0 : 1; }
EOF
    /source/chromium/src/third_party/llvm-build/Linux_x64/bin/clang \
      --target="$triple" \
      --sysroot="$sysroot" \
      -fuse-ld=lld \
      -I /sdk \
      /smoke/consumer.c \
      -L /sdk/Release \
      -Wl,-rpath,/sdk/Release \
      -lcef \
      -o /smoke/consumer
    exec "$loader" --library-path "$library_path" /smoke/consumer
    ;;
  cef-version-check)
    if [[ $# -ne 1 \
        || ! -f /source/chromium/src/cef/tools/version_manager.py ]]; then
      echo "error: cef-version-check requires the CEF source mount" >&2
      exit 64
    fi
    exec python3 /source/chromium/src/cef/tools/version_manager.py -c
    ;;
  cef-archive)
    if [[ $# -ne 3 \
        || ! "$2" =~ ^[A-Za-z0-9._+-]+\.tar\.gz$ \
        || ! "$3" =~ ^[0-9a-f]{24}$ \
        || ! -d /candidate/sdk \
        || ! -w /candidate/artifacts ]]; then
      echo "error: cef-archive requires a safe archive name, build ID, and candidate mount" >&2
      exit 64
    fi
    exec tar \
      -C /candidate \
      --sort=name \
      --mtime=@0 \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --use-compress-program='gzip -n' \
      -cf "/candidate/artifacts/$2" \
      "--transform=s,^sdk,$3," \
      sdk
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

case "${1:-}" in
  configure)
    if [[ $# -ne 2 ]]; then
      echo "error: configure requires the complete GN argument string" >&2
      exit 64
    fi
    exec /source/chromium/src/buildtools/linux64/gn \
      gen /build \
      "--args=$2"
    ;;
  gn-args)
    if [[ $# -ne 1 ]]; then
      echo "error: gn-args takes no arguments" >&2
      exit 64
    fi
    exec /source/chromium/src/buildtools/linux64/gn \
      args /build --list --short
    ;;
  build)
    if [[ $# -lt 3 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: build requires a positive job count and at least one target" >&2
      exit 64
    fi
    jobs="$2"
    shift 2
    exec /source/chromium/src/third_party/siso/cipd/siso \
      ninja --offline -local_jobs="$jobs" -C /build "$@"
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
    echo "error: expected Chromium builder mode: configure or build" >&2
    exit 64
    ;;
esac
