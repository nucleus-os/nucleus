# Chromium builder

These rootless Apple container images are the sole Linux environment for
building, packaging, and automatically validating CEF and Nucleus Browser for
Linux arm64 and x86_64.

Collider prepares the exact source graph, official Linux x86_64 build-host
tools, `depot_tools`, Chromium Linux clang, both target sysroots, PGO profiles,
and other downloads on the macOS host. A target-platform CIPD adapter lets the
macOS client materialize Linux packages without moving network access into a
container. The container receives those inputs read-only and has no network
access. Each product and target receives an independent persistent EXT4 GN
output at `/build` and ccache at `/ccache`; final artifacts cross back to the
host only through bounded candidate mounts.

The human-maintained package input is only `packages.txt`. The compact builder
manifest pins an Ubuntu snapshot and one `InRelease` digest per suite; Collider
derives package-index paths, sizes, and digests from that release metadata and
resolves the exact transitive package closure offline.

`Dependencies.Containerfile` defines the stable, content-addressed dependency
image. Collider derives two independent thin images from that exact local
digest: `build-entrypoint.sh` owns source materialization, configuration,
compilation, linking, and build tests; `artifact-entrypoint.sh` owns staging, packaging,
archiving, and artifact validation. Artifact-tool changes cannot invalidate a
product build, and neither thin image reinstalls the shared Linux package
closure.

The VM remains arm64. Chromium's official x86_64 Linux host tools use macOS 27
Intel binary translation. Target binaries are generated against their matching
Chromium sysroot. Automated validation executes arm64 artifacts natively. CEF's
x86_64 consumer link, ELF architecture, and direct dependency closure are
validated statically because Apple's translated loader cannot process CEF's
otherwise-valid, unusually large dynamic relocation table.
