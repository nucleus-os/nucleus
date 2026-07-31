# CEF product stage

Nucleus builds CEF from source with proprietary H.264/AAC codecs for the
embedded Apple Music surface. The production configuration includes:

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

The complete source selection lives in `../chromium/source.lock.json`. CEF
branch 7922 and Chromium 151.0.7922.19 are currently backed by exact clean
commits in the `nucleus-os` Chromium, CEF, ANGLE, V8, and Dawn forks. The
selected `depot_tools` commit is part of the same source identity.

Use the workspace entry point:

```sh
collider browser doctor
collider browser bootstrap
collider browser build
collider browser test
```

Collider materializes one locked source generation shared with Nucleus Browser.
It does not apply workspace patches or run CEF source-update automation. CEF's
translator and version manager run as idempotence checks, and publication
requires the CEF commit, tree, generated API hashes, and worktree to match the
lock exactly.

CEF builds in the external
`~/.cache/nucleus/cef/build/<source-id>/cef` output through the rootless,
offline Chromium builder. Packaging directly invokes the selected checkout's
`cef/tools/make_distrib.py` on the host to create a private minimal distribution;
Collider then creates the final Nucleus tarball, checksum, build manifest, and
atomic publication generation.

A distribution is accepted only when its identity still matches source
provenance, GN arguments, compiler, and PGO profiles. Before publication, a
small external consumer compiles, links, loads `libcef.so`, and calls
`cef_version_info`; unresolved dynamic libraries or API-hash failures reject
the artifact.

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

The shell consumes `dist/current/Release/libcef.so`, its matching
headers/wrapper, and resources from the same immutable generation.
