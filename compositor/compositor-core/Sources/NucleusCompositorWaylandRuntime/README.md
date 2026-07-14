# NucleusWaylandRuntime source farm

The substrate module is one Swift module whose sources live across three area
directories in the area-DAG layout:

- `valence/wayland/runtime/` — the libwayland-backed router + protocol impls
- `valence/xwayland/swift/`  — the ported XWM data layer
- `valence/input/swift/`     — the ported libinput/libseat/xkb input stack

A SwiftPM target has a single source root, so this directory holds symlinks to
each real source (the files stay in their area dirs while the Zig build still
references them). The set mirrors the explicit `sources` list of the
`NucleusWaylandRuntime` `addSwiftModule` call in `build.zig`. When that list
changes, re-run the farm regeneration (symlink each listed file here by
basename; there are no basename collisions across the three dirs).
