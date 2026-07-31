# Nucleus native builder

This image is the hermetic Linux compilation environment for the render native
SDK. Collider selects the built image by content-addressed image ID, mounts the
resolved Skia checkout at `/src` read-only, and exposes only `/build` and
`/ccache` as writable state. Dependency synchronization and host-side GPU and
renderer validation intentionally run outside this image.
