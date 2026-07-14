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

So this component compiles CEF from source with those GN args. Building CEF also
builds Chromium — a long-running, disk-heavy job in the same class as
`swift-toolchain/build.sh` and `swift-android-sdk/build.sh`. Like those, it is
an explicit, independently-run build, **not** part of `tools/nucleus build all`.
Nucleus consumes the produced artifact, not the build.

## Version pinning

CEF adopted Chromium's branch numbering, so the CEF release branch equals the
Chromium branch (the third component of the Chromium version):

| CEF branch | Chromium tag        |
|------------|---------------------|
| `7871`     | `150.0.7871.115`    |

Branch `7871` pins `chromium_checkout: refs/tags/150.0.7871.115`. Bump the
branch in `scripts/cef-env.sh` (and mirror in `config/build-contract.json`) to
upgrade; building the branch produces a self-consistent dist whose wrapper and
headers match its own `libcef.so` — never mix a source build's `libcef.so` with
another distribution's wrapper.

## Building

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

Output (all under `~/.cache/nucleus/cef/`):

```
dist/<version>/                     extracted, ready-to-consume distribution
  Release/   libcef.so, chrome-sandbox, v8 snapshot, swiftshader,
             + symlinks to the Resources/ payload (icudtl.dat, *.pak, locales/)
  Resources/ icudtl.dat, *.pak, locales/
  include/   public C++ API headers
  libcef_dll/ wrapper source (compiled by the consumer)
dist/cef-<version>-linux64-codecs.tar.gz(.sha256)   checksummed artifact
dist/latest.json                    pointer to the freshest build
logs/latest.log, logs/latest-run.env
```

## How the shell consumes it

The shell's build points at `dist/<version>/` (or unpacks the tarball): link
`libcef.so` from `Release/`, compile the `libcef_dll` wrapper, and set the CEF
resource paths to `Release/` (ICU initializes before resource-dir settings
apply, so `icudtl.dat` must sit beside `libcef.so` — the build colocates it
there via symlinks).

The current C++ noctalia shell's `scripts/fetch_cef.py` can be re-pointed at
this artifact instead of the stock CDN download; the future Swift/nucleus shell
consumes the same artifact path.

## Disk & resources

A shallow Chromium checkout plus a Release build is on the order of ~100 GB
under `~/.cache/nucleus/cef/`. The build saturates all cores; `ccache`
(shared `~/.cache/ccache`) makes subsequent rebuilds cheap.
