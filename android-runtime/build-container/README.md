# AOSP build container

Collider prepares two thin Ubuntu 26.04 LTS images above the shared, pinned
native dependency image. The build image owns AOSP compilation. The artifact
image owns local-development signing, image assembly, and validation. Changes
to artifact processing therefore do not invalidate the expensive AOSP compile
task.

Collider downloads pinned base-image and Ubuntu-package inputs on the macOS
host. Image assembly, AOSP compilation, signing, and validation run with no
container network access. Compilation and signing are rootless with all
capabilities dropped, `no-new-privileges`, a read-only container filesystem, an
ephemeral home, and only their explicit input and output mounts.

Production signing does not use the local-development identity or Collider's
signing task. It consumes the unsigned target-files archive in a separately
administered offline or restricted signing environment using standard AOSP
release tools.
