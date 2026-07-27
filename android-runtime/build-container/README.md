# AOSP build container

This Ubuntu 26.04 LTS image is the only environment used by Collider to compile
and perform local-development signing of Nucleus Android images. Its base image
is pinned by digest.

The image build may use the network to obtain the pinned base and Ubuntu
packages. AOSP compilation and signing run rootless with no network, all
capabilities dropped, `no-new-privileges`, a read-only container filesystem,
an ephemeral home, and only their explicit input and output mounts.

Production signing does not use the local-development identity or Collider's
signing task. It consumes the unsigned target-files archive in a separately
administered offline or restricted signing environment using standard AOSP
release tools.
