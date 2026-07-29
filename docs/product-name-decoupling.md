# Product Name Decoupling

## Invariant

No source file, build script, manifest, or generated artifact contains a literal
product name. Every runtime identifier — filesystem path, environment variable,
D-Bus name, socket name, desktop-file ID, user-visible string — derives from a
single declaration. Module, target, directory, and symbol names carry domain
meaning and no product branding.

A fork changes five fields in one file and rebuilds. Nothing else.

## Measured baseline

Every count below is over the working tree excluding `.build/`, `out/`,
`.nucleus/`, `third-party/`, `swift-toolchain/`, `android-runtime/.aosp-source/`,
`node_modules/`, and `.git/`. Re-measure before starting; these are the
completion targets.

| Surface | Count |
|---|---|
| Occurrences in source (`.swift`, `.h`, `.c`, `.cpp`, `.hpp`) | ~60,000 |
| — inside string literals | 3,931 |
| — identifiers | ~56,000 |
| SwiftPM target names carrying the product name | 255 of 314 |
| Directories named for the product | 678 |
| Files named for the product | 2,475 |
| Distinct `nucleus_*` C symbols | 384 |
| `@_spi` group names | 5 |
| Real environment variables | 28 |
| C header include guards (`NUCLEUS_*_H`) | 28 |
| Distinct path strings | 427 |
| Non-source files (sh/json/toml/gradle/xml/yml) | 853 |
| Reverse-DNS namespaces | 2 (`dev.nucleus` ×35, `org.nucleus` ×20) |

Header include guards are identifier-class, not contract-class. They are handled
in phase 8, not with the environment variables in phase 4.

## Phase 1 — Consolidate the reverse-DNS namespace

Two namespaces are in use. `dev.nucleus` is canonical; `org.nucleus` is retired.

Rewrite every `org.nucleus.*` to `dev.nucleus.*`. The affected identifiers are
the D-Bus error names in `platform-linux/Sources/NucleusLinuxDBus/`
(`org.nucleus.DBus.Error.Closed`, `.InvalidConnection`, `.InvalidReply`,
`.System`), `org.nucleus.gamma`, `org.nucleus.fixture`, and
`org.nucleus.collider.pseudo`.

No name here is registered with an external authority, so no compatibility alias
is kept.

**Gate:** zero matches for `org\.nucleus`; full build and full suite pass.

## Phase 2 — Establish the identity source of truth

Create `product.json` at the repository root:

```json
{
  "name": "nucleus",
  "displayName": "Nucleus",
  "reverseDNS": "dev.nucleus",
  "envPrefix": "NUCLEUS",
  "toolName": "collider"
}
```

These five fields are the only place a product name appears after this plan
completes.

Create a leaf SwiftPM target `ProductIdentity` at
`foundation/Sources/ProductIdentity` with no dependencies, so every other target
can depend on it without cycles. It exposes the five fields plus derived
accessors:

- `cacheDirectory` → `$XDG_CACHE_HOME/<name>`, falling back to `~/.cache/<name>`
- `configDirectory` → `$XDG_CONFIG_HOME/<name>`, falling back to `~/.config/<name>`
- `runtimeDirectory` → `$XDG_RUNTIME_DIR/<name>`
- `env(_ suffix: String)` → `<envPrefix>_<suffix>`
- `busName(_ suffix: String)` → `<reverseDNS>.<suffix>`
- `desktopFileID(_ component: String)` → `<reverseDNS>.<component>`
- `socketPath(_ component: String)` → `runtimeDirectory/<name>-<component>.sock`

The Swift source is generated from `product.json` by a build plugin modelled on
`swift-wayland/Plugins/GenerateWayland`, which already performs data-file →
Swift generation as a plugin. The generated file is the only Swift source
containing the literals.

Two non-Swift consumers read the same file as part of this phase:

- `tools/product-identity.sh` is generated from `product.json` and sourced by
  `collider-setup.sh` and `tools/host-env.sh`.
- `Package.swift` reads `product.json` directly at manifest evaluation for the
  package name and product names. `Package.swift` is Swift and may use
  `FileManager`, so no plugin is involved.

**Gate:** a behavioral test in `foundation/Tests/ProductIdentityTests` asserts
that each derived accessor composes correctly from the declared fields — for
example that `busName("DBus.Error.Closed")` equals
`"dev.nucleus.DBus.Error.Closed"`, and that `cacheDirectory` honours
`XDG_CACHE_HOME` when set and falls back when not. Do not assert that any
particular constant equals `"nucleus"`; that is the value under change, and
pinning it defeats the purpose.

## Phase 3 — Route the tool name

`collider` is user-facing: it is installed on `PATH` by `collider-setup.sh` and
invoked by name in documentation and scripts. It becomes
`ProductIdentity.toolName`.

The executable product name in `Package.swift` derives from `product.json`. The
launcher installation in `collider-setup.sh` derives from
`tools/product-identity.sh`. The cache directory `.nucleus/` and the build output
root derive from `ProductIdentity.cacheDirectory`.

This phase precedes the remaining contract phases because every subsequent gate
is verified by invoking the tool.

**Gate:** `collider doctor` and `collider build` succeed when invoked under the
installed name; no script contains a literal `collider`.

## Phase 4 — Route environment variables

Twenty-eight real environment variables move to `ProductIdentity.env(_:)`. They
are identified by their read sites — `getenv`, `ProcessInfo.processInfo
.environment`, `setenv`, and shell `export` — not by name pattern, because the
name pattern also matches header include guards.

The set includes `NUCLEUS_CONTROL_SOCKET`, `NUCLEUS_RUN_DIR`, `NUCLEUS_RUN_LOG`,
`NUCLEUS_EPHEMERAL_CONFIG`, `NUCLEUS_NATIVE_SDK_ROOT`, `NUCLEUS_ANDROID_NDK_HOME`,
`NUCLEUS_LAVAPIPE_ICD`, `NUCLEUS_ADDRESS_SANITIZER_SCOPE`,
`NUCLEUS_BENCHMARK_SWIFT_VERSION`, the `NUCLEUS_SESSION_FIXTURE_*` family, and
the `COLLIDER_*` family.

Shell consumers use the generated `tools/product-identity.sh` rather than
hardcoding the prefix.

**Gate:** no literal `NUCLEUS_` or `COLLIDER_` outside the generated Swift file,
the generated shell file, and C header include guards.

## Phase 5 — Route filesystem paths

The 427 distinct path strings reduce to a small set of roots, all of which move
behind the phase 2 accessors:

- `~/.cache/nucleus` and `~/.cache/nucleus/nucleus-native-sdk`
- `.nucleus/` in the working tree
- the run directory, log directory, and control socket
- `/nucleus-test.sock` and other test fixture sockets

`XDG_*` variable names are not ours and are never rewritten.

**Gate:** a bootstrap from a cold cache resolves every path; no literal
`nucleus` appears in a path expression outside the generated files.

## Phase 6 — Route protocol and desktop identity

Everything an external system sees by name:

- D-Bus error names and any bus name the process owns, via
  `ProductIdentity.busName(_:)`
- desktop-file IDs — `dev.nucleus.Browser.desktop`, `dev.nucleus.graphics`,
  `dev.nucleus.theme` — via `ProductIdentity.desktopFileID(_:)`
- the Wayland socket name
- the `XDG_CURRENT_DESKTOP` value the session advertises, and the `UseIn=` value
  a portal backend will declare

The last two do not exist yet. They are added in this phase as derived
accessors so that the portal work consumes them rather than introducing new
literals.

**Gate:** the AT-SPI live tests in
`platform-linux/desktop/Tests/NucleusLinuxAccessibilityTests` pass against a
private bus, since they exercise bus-name ownership end to end.

## Phase 7 — Route user-visible strings

Window titles, about text, log prefixes, and any other string a user reads move
to `ProductIdentity.displayName`. Localized text keeps its key and substitutes
the display name at format time.

**Gate:** the rename smoke test below.

### Rename smoke test

This is the proof the contract half is complete, and it runs as the closing step
of phase 7.

Change all five fields in `product.json` to an unrelated name. Rebuild. Run the
full suite. Confirm that no artifact, path, bus name, environment variable, or
emitted string contains the original name, by searching the build output tree
and the generated artifacts. Restore `product.json`.

If any occurrence of the original name survives, the phase is not complete and
the surviving site is routed before proceeding.

## Phase 8 — Rename C symbols and header guards

384 distinct `nucleus_*` C symbols and 28 `NUCLEUS_*_H` include guards.

These are internal — nothing outside the build links against them — so they
carry no product branding and no derived prefix. Each takes the domain of its
owning target: `nucleus_secure_zero` becomes `secure_memory_zero`,
`nucleus_dbus_error_init` becomes `dbus_shim_error_init`. Include guards follow
the same domain, so `NUCLEUS_SECURE_MEMORY_C_H` becomes `SECURE_MEMORY_C_H`.

Symbols declared `static inline` have no external linkage and cannot collide, so
they need no disambiguating prefix at all. Non-inline symbols keep a domain
prefix specific enough to avoid collision with system libraries, and keep their
`extern "C"` guards — every Swift target now parses C headers in C++ mode, so a
missing guard is a link error.

**Gate:** full build and full suite; no `nucleus_` in any C symbol.

## Phase 9 — Rename `@_spi` groups

Five groups: `NucleusCompositor`, `NucleusPlatform`, `NucleusRenderServer`,
`NucleusShellTesting`, `NucleusWindowClientImplementation`. Each drops the
prefix — `@_spi(Compositor)`, `@_spi(Platform)`, and so on.

A group name must match exactly between the declaring and importing module, so
every mismatch is a compile error. The rename is wide but self-verifying.

**Gate:** full build.

## Phase 10 — Rename targets, modules, and the directory tree

255 target names, 678 directories, 2,475 files.

The prefix is dropped, not replaced. `NucleusRenderModel` becomes `RenderModel`,
`NucleusCompositorWaylandRuntime` becomes `CompositorWaylandRuntime`,
`NucleusLinuxDBus` becomes `LinuxDBus`, `NucleusUI` becomes `UI`. Inside a
monorepo containing only this product the prefix carried no information, and a
fork inherits neutral names rather than a name it must also change.

Three constraints make this a single operation rather than an incremental one:

1. `Package.swift` pairs every `name:` with an explicit `path:`, so a target
   rename and its directory move must land together or the manifest breaks.
2. Module names appear in `import` statements across the tree, so a partial
   rename does not build.
3. Test targets reference their subject module by name, and the manifest pins
   each test target's `path:` explicitly — a test directory that moves without
   its manifest entry becomes silently inert rather than failing.

Constraint 3 is the dangerous one. Verify by test count, not by exit code: the
suite currently reports 1,914 tests across 258 suites in 67 test targets. A
rename that drops a target produces a passing run with a lower count.

Generated code is renamed at its generator, never at its output.
`swift-wayland/Sources/SwiftWaylandGenerator` and the React Native codegen emit
names; editing emitted files means the next regeneration reverts the rename.

**Gate:** full build; suite reports 1,914 tests across 258 suites; the count is
compared explicitly rather than assumed.

## Phase 11 — Rename remaining files and documentation

853 non-source files — shell scripts, JSON, TOML, Gradle, XML, YAML, desktop
entries — plus `docs/`, `core/docs/`, and every `README.md`.

`AGENTS.md` is rewritten last, once the tree it describes is settled. Its build
system section names specific modules and paths throughout and will be
substantially wrong until this phase.

**Gate:** the baseline measurement commands return zero outside the excluded
trees and `product.json`.

## Do not

- Do not rename anything under `third-party/`, `swift-toolchain/`,
  `android-runtime/.aosp-source/`, or `node_modules/`. Submodules are detached
  upstream checkouts; the fork policy in `AGENTS.md` governs them.
- Do not edit generated output. Change the generator.
- Do not rewrite `XDG_*` names. They belong to the freedesktop specification.
- Do not run `rm -rf .build`. Phases 8 through 10 invalidate caches heavily and
  the temptation is strong; a stale-artifact symptom is a build-graph bug worth
  finding.
- Do not pin the product name in a test. Tests assert derivation and
  composition, never the value of `name` or `displayName`.
- Do not treat a passing suite as sufficient after phase 10. Compare the test
  count.
- Do not reorder phases. Phase 2 defines what later phases consume, phase 3
  supplies the tool every later gate is run with, and the phase 7 smoke test is
  meaningless before phases 4 through 6 land.

## Verification commands

Baseline and completion are measured with the same commands. `EX` is the
exclusion set named under *Measured baseline*.

```sh
# Occurrences in source
find . $EX -prune -o -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' \
  -o -name '*.cpp' -o -name '*.hpp' \) -print | xargs grep -ohEi 'nucleus|collider' | wc -l

# Inside string literals only
... | xargs grep -ohE '"[^"]*([Nn]ucleus|[Cc]ollider)[^"]*"' | wc -l

# Real environment variables, by read site rather than name pattern
... | xargs grep -ohE '(getenv|environment\[|setenv|export )[^\n]{0,60}' \
  | grep -oE '\b(NUCLEUS|COLLIDER)_[A-Z0-9_]+' | sort -u | wc -l

# Directories and files named for the product
find . $EX -prune -o -type d \( -name '*ucleus*' -o -name '*ollider*' \) -print | wc -l
find . $EX -prune -o -type f \( -name '*ucleus*' -o -name '*ollider*' \) -print | wc -l

# Test count, compared against 1,914 tests / 258 suites / 67 targets
swift test 2>&1 | grep -oE 'Test run with ([0-9]+) tests?' \
  | grep -oE '[0-9]+' | paste -sd+ | bc
```

## Sequencing against other work

Phases 1 through 7 land before the D-Bus session-service work begins. That work
introduces bus names, a portal backend `UseIn=` value, a `.portal` config file,
and a socket — all contract-class identifiers. Landing the identity layer first
means they derive from `product.json` at the moment they are written, rather
than becoming further literals to find later.

Phases 8 through 11 have no such coupling and are ordered purely by risk: symbol
and SPI renames are compile-verified, the target and directory rename is the
only step where a mistake can pass silently, and documentation settles last.
