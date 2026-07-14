#!/usr/bin/env bash
# Regenerate Dawn's vendored codegen output from the Dawn submodule under
# Skia. Run after rolling the Skia submodule (which `tools/git-sync-deps`
# also bumps the Dawn submodule for) so the generated headers match the
# Dawn version Skia M-current source expects.
#
# Inputs:  third-party/skia/third_party/externals/dawn/{src/dawn,generator,...}
# Outputs: build_zig/generated/dawn_gen/{include,src,webgpu-headers}/...
#
# Usage:
#   tools/regenerate-dawn.sh

set -euo pipefail

if [ ! -f Package.swift ]; then
    echo "regenerate-dawn: run from the repo root" >&2
    exit 1
fi

DAWN=third-party/skia/third_party/externals/dawn
OUT=build_zig/generated/dawn_gen

if [ ! -d "$DAWN/generator" ]; then
    echo "regenerate-dawn: $DAWN/generator missing; submodules unsynced?" >&2
    echo "                 try: python3 third-party/skia/tools/git-sync-deps" >&2
    exit 1
fi

if ! python3 -c "import jinja2, markupsafe" 2>/dev/null; then
    echo "regenerate-dawn: python3 modules jinja2 + markupsafe are required" >&2
    echo "                 Ubuntu: sudo apt install python3-jinja2 python3-markupsafe" >&2
    exit 1
fi

# DawnJSONGenerator targets used by Dawn's CMake build. Native (non-Emscripten)
# only — emdawnwebgpu targets are excluded.
TARGETS="headers,cpp_headers,proc,webgpu_headers,wire,native_utils,webgpu_dawn_native_proc,dawn_utils"

# Clear and recreate the output dir so deleted-upstream files don't linger.
rm -rf "$OUT"
mkdir -p "$OUT"

export PYTHONPATH="$DAWN/generator${PYTHONPATH:+:$PYTHONPATH}"

echo "regenerate-dawn: dawn_json_generator targets=$TARGETS"
python3 "$DAWN/generator/dawn_json_generator.py" \
    --root-dir "$DAWN" \
    --template-dir "$DAWN/generator/templates" \
    --output-dir "$OUT" \
    --dawn-json "$DAWN/src/dawn/dawn.json" \
    --wire-json "$DAWN/src/dawn/dawn_wire.json" \
    --native-json "$DAWN/src/dawn/dawn_native.json" \
    --kotlin-json "$DAWN/src/dawn/dawn_kotlin.json" \
    --webgpu-kt-docs "$DAWN/src/dawn/webgpu_kt_docs.json" \
    --targets "$TARGETS"

echo "regenerate-dawn: dawn_version_generator"
python3 "$DAWN/generator/dawn_version_generator.py" \
    --root-dir "$DAWN" \
    --template-dir "$DAWN/generator/templates" \
    --output-dir "$OUT" \
    --dawn-dir "$DAWN"

echo "regenerate-dawn: dawn_gpu_info_generator"
python3 "$DAWN/generator/dawn_gpu_info_generator.py" \
    --root-dir "$DAWN" \
    --template-dir "$DAWN/generator/templates" \
    --output-dir "$OUT" \
    --gpu-info-json "$DAWN/src/dawn/gpu_info.json"

count=$(find "$OUT" -type f | wc -l)
echo "regenerate-dawn: wrote $count files to $OUT"
