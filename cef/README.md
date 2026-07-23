# CEF product stage

Nucleus builds CEF from source with proprietary H.264/AAC codecs for the
embedded Apple Music surface. Stock CEF binary distributions omit those
codecs, while this build fixes:

```text
proprietary_codecs=true
ffmpeg_branding=Chrome
use_dbus=true
is_official_build=true
chrome_pgo_phase=2
use_thin_lto=true
use_lld=true
use_siso=true
```

CEF branch `7922`, CEF commit
`6c664b86a4ef3be5c95b1290068f5e5d52b72db3`, Chromium
`151.0.7922.19` at commit
`8f914546f6536ee67a34edb3607f946616f55994`, and depot_tools commit
`35892a9e24190cc5f3a511d3954319c93445926c` are one indivisible input.
`automate-git.py` is downloaded from that exact CEF commit.

Use the workspace entry point:

```sh
tools/nucleus chromium doctor
tools/nucleus chromium bootstrap
tools/nucleus chromium build
tools/nucleus chromium test
```

`cef/build.sh` is an internal stage and intentionally exposes no independent
update, cleanup, product, GN-extra, build-only, or package-only workflow.

CEF patches live in `patches/`. Generic Chromium and Dawn changes live under
`../chromium/patches/`. They are applied once while constructing the shared,
content-addressed source generation. CEF's generated C/C++ bridge and API hashes
are regenerated and checked before the generation is published.

The CEF output has its own build identity. A minimal distribution is accepted
only when the identity still matches the source, GN arguments, compiler, and
PGO profiles. Before publication, a small external consumer compiles, links,
loads `libcef.so`, and calls `cef_version_info`; unresolved dynamic libraries
or API-hash failures reject the artifact.

Published layout:

```text
~/.cache/nucleus/cef/dist/
  releases/<build-id>/
    sdk/{Release,Resources,include,libcef_dll}/
    sdk/nucleus-build-manifest.json
    artifacts/cef-<version>-linux64-codecs.tar.gz
    artifacts/cef-<version>-linux64-codecs.tar.gz.sha256
    artifacts/nucleus-build-manifest.json
  current-release -> releases/<build-id>
  current -> current-release/sdk
  artifacts-current -> current-release/artifacts
```

The shell continues to consume `dist/current/Release/libcef.so`, its matching
headers/wrapper, and resources colocated beneath the same immutable generation.
