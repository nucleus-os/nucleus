# Nucleus native builder

This directory belongs to Collider because the image is build infrastructure,
not part of the portable Nucleus core. It defines the hermetic Linux environment
used by the native SDK and product build lanes.

Collider reads `native-builder-inputs.json`, downloads every digest-pinned
archive and each pinned Ubuntu 26.04 snapshot `InRelease` file on the macOS
host, and keeps those files in the persistent Nucleus cache. The signed release
metadata supplies the package-index paths, sizes, and digests. Collider then
runs `resolve-apt-packages.sh` in an offline resolver image to generate the
exact transitive package closure. The generated dependency build context
contains all archives and packages, so every image build runs with no network
or DNS attachment.

`Dependencies.Containerfile` defines the stable, content-addressed dependency
image shared by native SDK and AOSP work. Collider adds component-owned thin
entrypoint images above that exact local dependency-image digest. The native
SDK entrypoint remains here; AOSP build and artifact entrypoints live under
`android-runtime/build-container`, and the gfxstream entrypoint lives under
`android-runtime/gfxstream-build-container`. Entrypoint-only changes never
repeat package extraction or toolchain assembly and do not invalidate unrelated
components.

`apt-install-packages.txt` and `apt-extract-packages.txt` are the small,
human-maintained package requests. The expanded package closure is generated
from the pinned indexes and is never maintained by hand or checked into the
repository. Ubuntu's packaged Vulkan 1.4 loader is the build and test loader;
Nucleus does not compile or stage a private loader.

Collider selects the finished image by content-addressed image ID and exposes
only the explicitly declared source, output, and cache mounts to each action.
Each thin entrypoint rejects commands whose required mounts are absent.
