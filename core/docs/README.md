# Nucleus docs — reading guide

> **Read this first.** Many documents here predate two large migrations and
> describe designs in the terms of the architecture at the time of writing.
> The design intent in a given doc usually still stands; the *mechanics* it
> cites (file paths, build commands, module and brand names) may be historical.

## The migrations that reshaped everything

1. **Zig → Swift / SwiftPM (+ C++ interop).** The compositor, render server, and
   client runtime were originally Zig; they are now Swift built with SwiftPM,
   with C++ libraries (Skia Graphite, ReactCommon/Hermes/folly) reached through
   C++ interop. Treat `.zig` file paths, `build.zig`, `zig build`, `@cImport`,
   and a `src/{compositor,render_server,nucleon,valence}/` layout as
   **the pre-migration substrate**, not the present one.
2. **Brand collapse + package decomposition.** The `Nucleon` and `Valence` brands were
   retired and the tree split into independently buildable core, React Native, compositor,
   and shell packages.
   Name mappings when a doc uses the old vocabulary as if current:
   - `Nucleon` (project/module) → `Nucleus` / `NucleusUI`; `Valence*` → `NucleusCompositor*`.
   - The layer system **Dynamics → Layers**: module `NucleusDynamics` → `NucleusLayers`;
     `DynamicsHost` → `Host`, `DynamicsSettings` → `Settings`, `dynamicsColor` →
     `layersColor`, `dynamicsPolicy` → `layersPolicy`, etc. (`LayerTransaction` is a
     deliberate exception — it keeps its qualifier.)
   - The `nucleon/` source directory is gone: its contents folded into
     `swift/Sources/*` and `render-cxx/`.
3. **Monorepo consolidation.** The package boundaries remain, but `core/`, `react-native/`,
   `compositor/`, and `shell/` now share one Git repository and use relative SwiftPM paths.
   First-party nested submodules and sibling-repository overrides are historical.

## Where the current state actually lives

For how the tree is sliced and where code lives **today**, the authoritative
references are:

- the **Build System** section of the monorepo-root `AGENTS.md`, and
- the monorepo root `README.md`.

`docs/naming-and-core-split-migration.md` records the brand-collapse migration
itself — there the old names are the intended "from" side, by design.

## So when you read a plan here

Take the **invariants and reasoning** as live unless a
newer doc supersedes them. Take specific paths, build incantations, and old brand
names as needing the mapping above. When a doc has been reconciled to current
names, it simply reads correctly; when it hasn't, this guide is the decoder.
