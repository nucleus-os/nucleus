# cef

Build script for the Chromium Embedded Framework (CEF) **with proprietary
codecs** (H.264/AAC), targeting `x86_64-linux`. Produces a minimal CEF binary
distribution (`libcef.so` + `libcef_dll` wrapper source + resources) plus a
checksummed tarball under `~/.cache/nucleus/cef/dist/`, consumed by the desktop
shell's embedded browser (the in-shell Apple Music surface).

## Why this is separate — and why it must be built from source

Official CEF distributions (and every prebuilt wrapper) ship with
`proprietary_codecs=false`: no H.264, no AAC, no MP4. That exclusion exists
because redistributing binaries with those patented codecs requires MPEG-LA /
Via-LA licensing. There is no drop-in fix — CEF statically links ffmpeg into
`libcef.so`, so you cannot swap in a codec-enabled `libffmpeg.so` the way older
Chromium/Electron layouts allowed.

The embedded browser's target — Apple Music web — streams **AAC audio under
Widevine**. Widevine EME itself already works in stock CEF (external CDM
loading is enabled by default; verified with VP9/Opus). The missing piece is
purely the AAC/H.264 decoders, which only appear when Chromium is compiled with:

    proprietary_codecs=true
    ffmpeg_branding=Chrome
    use_dbus=true

`use_dbus=true` hard-requires Chromium's native Linux MPRIS backend. The browser
process exports its active Media Session as `org.mpris.MediaPlayer2.chromium.instance<PID>`,
including metadata, artwork, position, and transport controls.

So this component compiles CEF from source with those GN args. Production CEF
is additionally a Chromium official build: DCHECKs and expensive DCHECKs are
disabled, the exact branch-matched Linux PGO profile is applied, and optimized
ThinLTO links with LLD. The build script provisions both Chromium's Linux
instrumentation profile and V8's version-matched builtins profile. Building CEF also
builds Chromium — a long-running, disk-heavy job in the same class as
`swift-toolchain/build.sh` and `swift-android-sdk/build.sh`. Like those, it is
an explicit, independently-run build, **not** part of `tools/nucleus build all`.
Nucleus consumes the produced artifact, not the build.

The project patch stack implements direct Viz offscreen output for explicitly
requested Linux accelerated OSR. A generic Mojo contract carries an exportable
root frame and the matching consumer release fence between the browser and Viz
processes; a four-slot native-pixmap SharedImage queue renders the final root
pass directly, so the production path does not create a video capturer or
perform its full-surface capture blit. Ordinary Chromium compositors and
upstream capture modes remain unchanged.

CEF-only patches live directly under `patches/`. Shared Chromium and Dawn
changes live under `../chromium/patches/`, alongside the standalone Chromium
browser layer and shared build entry point. Every preparation produces one
cumulative patched source tree for both products, while each product retains
its own immutable GN output directory. A CEF-owned follow-up patch gates the
upstream OSR software proxy on `enable_cef`, so the browser can set
`enable_cef=false` without carrying CEF-only source into its binary.

The NVIDIA VA-API driver's matching packed image export is maintained in the
pinned `maddythewisp/nvidia-vaapi-driver` fork. CUDA maps the packed plane
arrays without its dedicated-image flag; Dawn independently uses a dedicated
Vulkan allocation when the queried external-memory contract requires it.

## Version pinning

CEF adopted Chromium's branch numbering, so the CEF release branch equals the
Chromium branch (the third component of the Chromium version):

| CEF branch | Chromium tag        |
|------------|---------------------|
| `7922`     | `151.0.7922.19`     |

CEF commit `6c664b86a4ef3be5c95b1290068f5e5d52b72db3` on branch `7922`
pins `chromium_checkout: refs/tags/151.0.7922.19`. Both values are mandatory:
the release branch can advance to a newer Chromium patch version without
changing its branch number. Bump the commit and Chromium version together in
`scripts/cef-env.sh`; the resulting dist must
always ship the wrapper and headers built with its own `libcef.so`.

## Building

The workspace-level entry point is preferred because it also owns the
standalone Chromium browser layer:

```sh
chromium/build.sh cef
chromium/build.sh browser
chromium/build.sh all
```

`cef/build.sh` remains the CEF product primitive used by that entry point. It
is still useful directly for CEF-only packaging and recovery operations.

Once, on a fresh host, install Chromium's build dependencies (large; needs
sudo). Run one sync first so the checkout exists, then install deps:

```sh
cef/build.sh                       # first sync + build attempt
cef/build.sh --install-build-deps  # if the build failed on missing host deps
```

Normal build:

```sh
cef/build.sh                 # sync (shallow) + Release build + package
cef/build.sh --force-clean   # wipe the Chromium checkout and re-sync first
cef/build.sh --package-only  # re-package the last build without rebuilding
```

The shared Chromium orchestrator uses `cef/build.sh --prepare-only` followed by
`cef/build.sh --build-only` so CEF and the standalone browser can compile in
parallel only after all shared-source mutation has finished. These modes are
also useful for resuming an interrupted compile without repeating checkout and
patch preparation.

Packaging primitive regression test:

```sh
python3 cef/scripts/atomic-publish-directory-test.py
```

Output (all under `~/.cache/nucleus/cef/`):

```
dist/<version>/                     extracted, ready-to-consume distribution
  Release/   libcef.so, chrome-sandbox, v8 snapshot,
             + symlinks to the Resources/ payload (icudtl.dat, *.pak, locales/)
  Resources/ icudtl.dat, *.pak, locales/
  include/   public C++ API headers
  libcef_dll/ wrapper source (compiled by the consumer)
dist/cef-<version>-linux64-codecs.tar.gz(.sha256)   checksummed artifact
dist/current -> <version>/          stable pointer to the freshest build
logs/latest.log
```

Publication prepares the complete tree under a sibling temporary path, then
uses an atomic Linux directory exchange. An interrupted rebuild therefore
leaves either the old complete SDK or the new complete SDK visible, never a
mixed wrapper and `libcef.so`. It then atomically switches the `current`
symlink to the published version.

## How the shell consumes it

The shell's build points at `dist/current/`, an explicit `dist/<version>/`, or
an unpacked tarball: link
`libcef.so` from `Release/`, compile the `libcef_dll` wrapper, and set the CEF
resource paths to `Release/` (ICU initializes before resource-dir settings
apply, so `icudtl.dat` must sit beside `libcef.so` — the build colocates it
there via symlinks).

The current C++ noctalia shell's `scripts/fetch_cef.py` can be re-pointed at
this artifact instead of the stock CDN download; the future Swift/nucleus shell
consumes the same artifact path.

## Disk & resources

A shallow Chromium checkout plus an official PGO/ThinLTO Release build is on
the order of ~100 GB under `~/.cache/nucleus/cef/`. ThinLTO uses materially more
link memory and time than the developer Release configuration. The build
saturates all cores; `ccache` (shared `~/.cache/ccache`) makes subsequent
compilation cheaper, although the final optimized link remains substantial.
