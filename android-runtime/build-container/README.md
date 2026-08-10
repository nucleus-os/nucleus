# AOSP build container

This Ubuntu 26.04 LTS image is the only environment used by Collider to compile
and perform local-development signing of Nucleus Android images. Its base image
is pinned by digest.

Collider downloads pinned base-image and Ubuntu-package inputs on the macOS
host. Image assembly, AOSP compilation, and signing run with no container
network access. Compilation and signing are rootless with all capabilities
dropped, `no-new-privileges`, a read-only container filesystem, an ephemeral
home, and only their explicit input and output mounts.

Production signing does not use the local-development identity or Collider's
signing task. It consumes the unsigned target-files archive in a separately
administered offline or restricted signing environment using standard AOSP
release tools.
