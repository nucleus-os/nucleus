# Swift builder

This rootless Podman image is the only Linux environment used to build the
Nucleus Swift host toolchain and SwiftAndroid SDKs. The Ubuntu base, Android
NDK archive, and archive checksum are pinned in the Containerfile. Collider
records the resulting OCI image ID and uses that digest for every build task.

Compilation runs without networking, capabilities, host devices, the host home
directory, or writable source. The complete Swift sibling graph and recipe are
read-only mounts. Candidate, build, compiler-cache, staging, and artifact paths
are explicit writable mounts outside all source submodules.

The image also embeds a checksum-pinned official `release/6.4.x` Swift
snapshot. That compiler bootstraps Swift-written compiler and SwiftSyntax
sources only; the published toolchain is built entirely from the root-selected
source gitlinks.
