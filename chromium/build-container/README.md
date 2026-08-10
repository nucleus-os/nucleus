# Chromium builder

This rootless Apple container image is the sole Linux environment for building,
packaging, and automatically validating CEF and Nucleus Browser for Linux arm64
and x86_64.

Collider prepares the exact source graph, official Linux x86_64 build-host
tools, `depot_tools`, Chromium Linux clang, both target sysroots, PGO profiles,
and other downloads on the macOS host. A target-platform CIPD adapter lets the
macOS client materialize Linux packages without moving network access into a
container. The container receives those inputs read-only and has no network
access. Each product and target receives an independent persistent EXT4 GN
output at `/build` and ccache at `/ccache`; final artifacts cross back to the
host only through bounded candidate mounts.

`Dependencies.Containerfile` defines the stable, content-addressed dependency
image. Collider adds `entrypoint.sh` in a separate thin image layer based on the
exact local dependency-image digest. Editing orchestration code therefore does
not reinstall the Linux package closure or rebuild the tool environment.

The VM remains arm64. Chromium's official x86_64 Linux host tools use macOS 27
Intel binary translation. Target binaries are generated against their matching
Chromium sysroot. Automated validation executes arm64 artifacts natively and
x86_64 artifacts through the same translation facility with their explicit
target loader and libraries.
