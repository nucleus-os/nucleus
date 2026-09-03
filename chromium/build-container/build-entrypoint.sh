#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME"

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
    # The architecture argument is still required and no longer read. It
    # selected a sysroot to run against, which is what these suites stopped
    # doing; it stays because running an x86_64 suite in this arm64 container
    # is a separate question from building one, and that is where the answer
    # will have to go.
    if [[ $# -ne 3 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: test-ozone requires a positive job count and architecture" >&2
      exit 64
    fi
    /source/chromium/src/third_party/siso/cipd/siso \
      ninja --offline -local_jobs="$2" -C /build \
      ui/ozone:ozone_unittests \
      components/viz/service:output_presenter_ozone_unittests
    # Run these the way the artifact validators run theirs: the binary
    # directly, on the container's own loader, with only the build directory
    # on the library path.
    #
    # They were invoked through the loader found inside Chromium's sysroot,
    # with that sysroot's library directories ahead of everything. Both suites
    # then died of SIGSEGV before `--gtest_list_tests` could enumerate a single
    # test, which is process startup rather than anything a test does. The
    # sysroots are stripped compile and link inputs and are not runtime roots;
    # `validate-browser` and `validate-cef` both execute against the product's
    # own runtime for that reason, and both pass. A binary built against an
    # older sysroot runs on the newer glibc above it, which is the ordinary
    # arrangement and the one these suites now use.
    run_suite() {
        local name="$1" filter="$2" status=0
        # `stdbuf` preloads into the process it starts, which now is the test
        # itself rather than a foreign loader, so line buffering takes effect
        # and gtest's output survives a signal.
        if command -v stdbuf >/dev/null 2>&1; then
            stdbuf -oL -eL env LD_LIBRARY_PATH=/build \
                "/build/$name" "--gtest_filter=$filter" \
                --single-process-tests || status=$?
        else
            env LD_LIBRARY_PATH=/build \
                "/build/$name" "--gtest_filter=$filter" \
                --single-process-tests || status=$?
        fi
        if [[ "$status" -ne 0 ]]; then
            # A signal reads as 128 + n and is otherwise an unexplained number.
            if [[ "$status" -gt 128 ]]; then
                echo "error: $name terminated by signal $((status - 128))" >&2
            else
                echo "error: $name exited $status" >&2
            fi
            return "$status"
        fi
        echo "$name passed"
    }
    # Whether the binary can start at all, asked separately from whether its
    # tests pass. `--gtest_list_tests` enumerates and exits without running a
    # test body, so a crash here means the process dies before any test does,
    # and a clean listing means the crash belongs to a test. The previous
    # failure could not distinguish those: it reported a signal and nothing
    # else, and buffered output does not survive one.
    probe_start() {
        local name="$1" status=0
        env LD_LIBRARY_PATH=/build "/build/$name" \
            --gtest_list_tests >/dev/null 2>&1 || status=$?
        if [[ "$status" -eq 0 ]]; then
            echo "probe: $name starts and enumerates its tests"
        elif [[ "$status" -gt 128 ]]; then
            echo "probe: $name dies before running anything," \
                "signal $((status - 128))" >&2
        else
            echo "probe: $name cannot enumerate its tests, exit $status" >&2
        fi
    }
    probe_start ozone_unittests
    probe_start output_presenter_ozone_unittests
    run_suite ozone_unittests '*OzonePresenter*'
    run_suite output_presenter_ozone_unittests 'OutputPresenterOzoneTest.*'
    ;;
  *)
    echo "error: expected Chromium build command" >&2
    exit 64
    ;;
esac
