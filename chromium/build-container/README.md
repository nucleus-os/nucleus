# Chromium builder

This Apple `container` image is the only Linux compilation environment for CEF
and Nucleus Browser. It runs on the macOS ARM64 builder. Collider prepares the
exact source graph and depot_tools outside the image, then mounts both
read-only. Each product receives a separate external writable GN output mounted
at `/build`.

GN generation and Ninja compilation run without networking, capabilities,
host devices, the host home directory, or writable source. Packaging,
publication, executable tests, sandbox validation, and GPU/Wayland validation
remain host operations against the produced artifacts.
