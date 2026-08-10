# Chromium products

The Chromium component produces Linux arm64 and x86_64 variants of embedded
CEF and Nucleus Browser from one exact source generation. The supported command
surface is:

```sh
collider doctor browser
collider bootstrap browser
collider build browser
collider test browser
collider install browser
```

`bootstrap` prepares host-owned downloads and source. `build` compiles,
packages, and validates both architectures. `test` executes the focused
Ozone/Viz suites for both architectures. Product selectors, architecture
selectors, package-only modes, source-update bypasses, and ad hoc GN overrides
are unsupported.

## Source and network boundary

`source.lock.json` selects exact commits and trees in the genuine `nucleus-os`
Chromium, CEF, ANGLE, Skia, V8, and Dawn forks and the canonical `depot_tools`
commit. It has no format version; a source update replaces the complete lock.

Collider maintains bounded shallow object caches for the selected Chromium and
CEF repositories under `~/.cache/nucleus/cef/repository-cache`. It also keeps a
source-ID-scoped private candidate when dependency synchronization is
interrupted, so the next invocation resumes the same gclient checkout instead
of downloading it again. Collider first synchronizes the Linux target graph and
runs the source-generation hooks with native macOS tools. After CEF translation
is complete, a second host-side, no-hooks synchronization materializes the
official Linux x86_64 GN, Ninja, Siso, and other build-host inputs. A narrow
CIPD adapter substitutes the selected Linux host platform while the macOS CIPD
client performs every download. Collider then runs DevTools' source-pinned
Rollup synchronization script so its Linux x86_64 native module replaces the
macOS hook result. Collider also installs the Linux Chromium clang and arm64 and
amd64 sysroots, resolves the V8 builtins PGO profile used by both targets, and
verifies all selected commits and trees before atomically publishing the source
generation. The resulting provenance binds the source lock, build-host
platform, DEPS graph, compiler, sysroots, PGO profiles, and clean repository
identities.

Every network operation runs on the macOS host. Builder containers receive the
published source and downloaded inputs as read-only mounts and run with
networking disabled. `depot_tools` remains a host-only acquisition input;
container builds invoke the source-pinned Linux Siso executable directly.
Collider never applies patches, runs CEF's patcher, adopts a dirty checkout, or
repairs a published generation.

## Build workspaces and concurrency

CEF and Nucleus Browser each have independent Linux arm64 and x86_64 GN output
volumes and compiler-cache volumes. These Collider-owned persistent EXT4
workspaces contain only reconstructible intermediates. The source generation
and final publications remain ordinary host files; no Ninja output is written
through a host bind mount.

The four build branches are independent. Collider schedules up to two Apple
container build lanes concurrently, so the arm64 and x86_64 variants of a
product compile together when resources are available. Each lane receives 12
virtual CPUs and runs at 12-way Siso concurrency, using all 24 physical host
cores without oversubscription. The persistent Apple container service inherits
the host contract's 245,760-descriptor limit so both source graphs can remain
open concurrently. Native build systems retain responsibility for incremental
invalidation, and ccache persists across ephemeral containers and interrupted
runs.

Both targets use Chromium's official Linux x86_64 host tools inside the arm64
builder VM. macOS 27 Intel binary translation executes those tools. They
generate arm64 or x86_64 target code according to each branch's GN
configuration; no x86_64 Linux distribution or x86_64 VM is booted.

CEF disables Chromium's allocator shim and BackupRefPtr because `libcef.so`
loads into another process. The standalone browser retains PartitionAlloc, the
allocator shim, and BackupRefPtr. Both products use LLD, Siso, ccache, ThinLTO,
native Wayland, Graphite/Dawn/Vulkan, and no SwiftShader compositor fallback.

## Publication and validation

Each output volume contains `.nucleus-built-build.json`, binding its target
architecture, source provenance, resolved `args.gn`, Chromium clang, sysroot,
and PGO profile. Packaging rejects a missing or stale identity before copying
the bounded product into an immutable host generation.

CEF publishes beneath `~/.cache/nucleus/cef/dist/linux-arm64` and
`~/.cache/nucleus/cef/dist/linux-x86_64`. Nucleus Browser publishes beneath
`~/.cache/nucleus/cef/browser-dist/linux-arm64` and
`~/.cache/nucleus/cef/browser-dist/linux-x86_64`. Each target has its own
validated `current` symlink.

Artifact validation uses the matching Chromium target sysroot and dynamic
loader. The arm64 artifacts execute natively; x86_64 artifacts execute through
macOS 27 Intel binary translation. CEF validation cross-compiles, links, and
runs a real consumer for each target. Browser validation resolves the shipped
runtime and executes the browser version path for each target. Focused Ozone
and Viz tests execute in the same target-specific workspaces.

`collider install browser` installs the x86_64 desktop browser generation and
its Linux x64 Widevine payload. Dual-architecture build and publication do not
change that existing local installation contract.

Live Wayland, GPU, media, sandbox, Widevine, 120 Hz, and hardware behavior
remain explicit user-owned qualification after automated build and test gates.
