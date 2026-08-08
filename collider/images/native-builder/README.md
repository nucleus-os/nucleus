# Nucleus native builder

This directory belongs to Collider because the image is build infrastructure,
not part of the portable Nucleus core. It defines the hermetic Linux environment
used by the native SDK and product build lanes.

Collider reads `native-builder-inputs.json`, downloads every digest-pinned
archive and Ubuntu package index on the macOS host, and keeps those files in the
persistent Nucleus cache. It then runs `resolve-apt-packages.sh` in an offline
resolver image to generate the exact transitive package closure. The generated
final build context contains all archives and packages, so both image builds run
with no network or DNS attachment.

`apt-install-packages.txt` and `apt-extract-packages.txt` are the small,
human-maintained package requests. The expanded package closure is generated
from the pinned indexes and is never maintained by hand or checked into the
repository.

Collider selects the finished image by content-addressed image ID and exposes
only the explicitly declared source, output, and cache mounts to each action.
