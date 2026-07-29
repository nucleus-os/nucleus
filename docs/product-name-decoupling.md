# Product Identity Decoupling

## Invariant

`product.json` is the only authored declaration of product identity.

Generated sources, installed files, and runtime artifacts may contain the
configured identity, but every such value is mechanically derived from
`product.json`. No independently authored Swift, C, C++, Kotlin, JavaScript,
shell, Gradle, SwiftPM, systemd, desktop, portal, test, fixture, file, directory,
module, target, product, package, or symbol name duplicates the configured
product or tool branding.

Internal names describe domains. This applies to both existing brands:
`Nucleus…` becomes a domain name such as `RenderModel`, and `Collider…` becomes a
build-domain name such as `BuildRuntime`. The installed build command remains
user-facing and derives from `toolName`; its implementation has no matching
brand requirement.

A fork changes these five fields and rebuilds:

```json
{
  "name": "nucleus",
  "displayName": "Nucleus",
  "reverseDNS": "dev.nucleus",
  "envPrefix": "NUCLEUS",
  "toolName": "collider"
}
```

Nothing else is edited.

## Identity model

The fields have distinct contracts:

| Field | Purpose | Required form |
|---|---|---|
| `name` | Filesystem slug and freedesktop identity component | `[a-z][a-z0-9-]{0,62}` |
| `displayName` | Localizable user-visible product name | Nonempty Unicode without control characters |
| `reverseDNS` | D-Bus, desktop, Android, and packaging namespace root | At least two dot-separated `[a-z][a-z0-9]*` components; total length at most 200 bytes |
| `envPrefix` | Prefix for product-owned environment variables | `[A-Z][A-Z0-9_]*` |
| `toolName` | Installed build command name | `[a-z][a-z0-9-]{0,62}` |

The generator rejects path separators, `.` and `..` path components, empty
components, shell metacharacters, invalid D-Bus components, invalid environment
prefixes, and derived names that exceed their platform limits. Unix socket paths
are also checked at the point where their complete runtime parent is known.

The fields are intentionally independent. No code attempts to infer case,
display spelling, or a reverse-DNS namespace from another field.

## Decisions fixed before execution

The following decisions are part of the architecture. Later phases apply them;
they do not reopen them.

### Final repository topology

The first-party package roots settle as:

```text
build-tool/
  Package.swift
  engine/
    Package.swift
foundation/
core/
react-native/
compositor/
shell/
platform-linux/
ipc/
integration-tests/
```

`build-tool/` owns the workspace CLI, recipes, installation, qualification, and
its generic execution engine. The engine remains a separate SwiftPM package so
it cannot acquire dependencies on product packages. The repository root remains
the canonical first-party Swift package. Existing first-party package boundaries
outside the build tool remain unchanged by this migration.

The maintained executable product is `WorkspaceTool`. It is installed under the
configured `toolName`; no SwiftPM package, product, target, module, or source
directory is named after that installed command.

### Neutral naming grammar

All renamed identifiers use domain-before-role spelling:

- `RenderModel`, `BuildRuntime`, `ConfigurationService`
- `LinuxDBus`, `AndroidHostLifecycle`, `WindowClientRuntime`
- `CoreBuildRecipe`, `CompositorBuildRecipe`, `AndroidRuntimeBuildRecipe`

The suffixes have fixed meanings:

- `C` is a C module or C façade
- `Cxx` is a C++ module or C++ façade
- `Executable` is an executable's launch-only Swift target
- `Tests` is a behavioral test target
- `TestSupport` is reusable test support
- `Fixture` is a test-only executable or resource fixture

Acronyms use `DBus`, `IPC`, `JNI`, `GPU`, `DRM`, `GBM`, `XCB`, `XDG`, `PAM`,
and `Vulkan`. A renamed declaration follows the same spelling as its owning
module.

`Foundation`, `UI`, `App`, `Core`, `Runtime`, `Config`, `Linux`, `Android`,
`Shell`, and `Platform` are forbidden as standalone first-party module or target
names. The fixed replacements for otherwise ambiguous top-level names are:

| Branded role | Final neutral name |
|---|---|
| product foundation utilities | `RuntimeFoundation` |
| render/UI framework | `RenderUI` |
| application model | `ApplicationModel` |
| application host bundle | `ApplicationHostBundle` |
| configuration model | `ConfigurationModel` |
| Linux umbrella product | `LinuxPlatform` |
| Linux desktop umbrella product | `LinuxDesktop` |
| React Native runtime | `ReactRuntime` |
| compositor executable | `CompositorExecutable` |
| shell executable | `ShellExecutable` |
| control CLI executable | `ControlCLIExecutable` |

All other `Nucleus`-prefixed Swift names drop only that prefix when the result
already contains at least two domain/role words and does not collide with a
first-party, standard-library, SDK, or dependency module. `NucleusUI` is the
explicit exception and becomes `RenderUI`.

If prefix removal collides, prepend the narrowest owning subsystem from this
fixed order until unique: `Build`, `Render`, `WindowClient`, `Compositor`,
`Shell`, `React`, `Android`, `Linux`, `IPC`, `Configuration`. A declaration
collision inside one module prepends its owning type or module domain. A file
collision applies the same module domain to its basename. The neutralization
generator performs this resolution deterministically and emits an error only
when the source has no owning subsystem in this list.

The build-tool mapping is fixed:

| Current name | Final name |
|---|---|
| `collider/` | `build-tool/` |
| `collider/engine/` | `build-tool/engine/` |
| `collider-setup.sh` | `workspace-setup.sh` |
| `Collider` executable target | `WorkspaceTool` |
| `ColliderCommands` | `WorkspaceCommands` |
| `ColliderCore` | `BuildCore` |
| `ColliderRuntime` | `BuildRuntime` |
| `ColliderDownloads` | `BuildDownloads` |
| `ColliderPlatformC` | `BuildPlatformC` |
| `<Domain>ColliderRecipe` | `<Domain>BuildRecipe` |
| `ColliderCommandsTests` | `WorkspaceCommandsTests` |
| `ColliderCoreTests` | `BuildEngineTests` |

Before phase 2 changes source, the baseline tooling expands these rules into
`generated/product-identity/neutralization-map.json`. The map contains every
package, product, target, module, declaration family, C prefix, SPI group, file,
and directory rename. Generation fails on a collision or on a name requiring a
rule not stated above. Every later phase consumes this frozen map; it may not
invent a replacement name.

### Identity ownership classes

Every baseline occurrence is assigned exactly one class in
`generated/product-identity/ownership.json`:

1. `derived`: product-owned external or user-visible identity generated from
   `product.json`
2. `neutralized`: first-party internal branding replaced through the frozen
   neutralization map
3. `specified`: an identifier owned by a platform specification and preserved
4. `upstream`: an excluded upstream occurrence with repository path and
   provenance

Unclassified occurrences and path-only allowlists fail the audit. `upstream`
entries identify the submodule or package source; `specified` entries identify
the owning specification and exact contract. First-party exceptions are
prohibited.

### Closed product-contract catalog

Product-owned contracts are declared in the checked-in, identity-neutral
`tools/product-contracts.json` and emitted as typed generated members, not
assembled from arbitrary suffix strings. The public catalog is:

```text
identity.environment.nativeSDKRoot
identity.environment.swiftPMGeneratedModuleMaps
identity.environment.targetPlatform
identity.environment.controlSocket
identity.environment.sessionRuntimeDirectory
identity.environment.sessionID
identity.environment.runDirectory
identity.environment.runLog
identity.environment.ephemeralConfig
identity.environment.androidNDKHome
identity.environment.lavapipeICD
identity.environment.addressSanitizerScope
identity.environment.benchmarkSwiftVersion
identity.environment.sessionFixture*

identity.dbus.errors.closed
identity.dbus.errors.invalidConnection
identity.dbus.errors.invalidReply
identity.dbus.errors.system
identity.dbus.gamma
identity.dbus.fixture
identity.dbus.portalBackend

identity.desktop.browserApplication
identity.desktop.graphics
identity.desktop.theme
identity.desktop.currentDesktop
identity.desktop.portalUseIn

identity.android.libraryNamespace
identity.android.smokeApplicationID
identity.android.mavenGroup

identity.packaging.sessionUnit
identity.packaging.sessionService
identity.packaging.portalFile
identity.packaging.desktopFiles

identity.metrics.renderer
identity.metrics.accessibility
identity.metrics.text
identity.metrics.windowScene
identity.metrics.animation
identity.metrics.viewPublication
```

Phase 1 expands the `sessionFixture*` and other measured families into explicit
named entries in that checked-in catalog before any consumer changes. Wildcards
do not remain after phase 1. New product-owned identifiers added after this
migration must first add a typed catalog member. Raw `env(_:)`, `busName(_:)`,
`desktopFileID(_:)`, `androidNamespace(_:)`, and `metricName(_:)` composition
remains internal to the generated implementation and tests.

### External spelling

Derived contracts use these exact forms:

| Contract | Form |
|---|---|
| Environment variable | `<envPrefix>_<UPPER_SNAKE_SUFFIX>` |
| D-Bus name or interface | `<reverseDNS>.<UpperCamelSuffix>` |
| D-Bus error | `<reverseDNS>.DBus.Error.<UpperCamelError>` |
| Desktop-file ID | `<reverseDNS>.<UpperCamelComponent>.desktop` |
| Icon and application ID | `<reverseDNS>.<UpperCamelComponent>` |
| `XDG_CURRENT_DESKTOP` | `<name>` |
| Portal `UseIn=` | `<name>` |
| Portal backend ID | `<reverseDNS>.Portal` |
| systemd unit basename | `<name>-<kebab-domain>` |
| Android library namespace | `<reverseDNS>.android` |
| Android smoke application ID | `<reverseDNS>.android.smoke` |
| Maven group | `<reverseDNS>` |
| Maven artifact | `<name>-android` |
| Metric or tracing namespace | `<reverseDNS>.<lower_snake_domain>` |
| Installed workspace command | `<toolName>` |

Neutral protocol-local values remain unbranded: `wayland-0`, `control.sock`,
`environment.sh`, and similar names derive uniqueness from their owning
directory or protocol.

### Configuration access

Only process composition roots, the workspace tool, packaging generators, and
tests may access `ProductIdentity.configured`. Libraries receive typed contract
values, resolved paths, or configuration structs through initializers. Generic
build-engine targets never import `ProductIdentity` and never parse
`product.json`.

`displayName` is the configured spelling in every locale. Localization keys are
neutral and localized sentences interpolate `displayName`; the identity itself
is not a localization key.

### Identity changes, caches, and compatibility

Changing identity selects new cache, configuration, workspace-state, versioned
install payload, and runtime roots. Existing branded roots are not migrated,
read, aliased, or deleted. Only an owned obsolete launcher is removed under the
installation rule above. Content-addressed upstream download storage is
product-independent and moves to a neutral build-engine cache; derived native
SDKs and build artifacts remain identity-scoped.

Branded public APIs, package products, environment variables, launchers, and
protocol names are deleted without compatibility wrappers.

### Android API and JNI shape

Android implementation Kotlin moves to the private package
`runtime.android.render`. Its implementation types are `RenderPlatform`,
`RenderHost`, `RenderView`, `RenderException`, and `NativeBridge`.

The generator emits the public façade under `<reverseDNS>.android` with the
types `Platform`, `PlatformHost`, `PlatformView`, and `PlatformException`.
Swift-Java consumes the generated package property and owns binding generation.
JNI uses explicit generated `RegisterNatives` tables; exported function names do
not encode a Java package or product name. Gradle reads the generated namespace,
application ID, Maven group, and artifact ID and has no fallback defaults.

The smoke application lives under the generated
`<reverseDNS>.android.smoke` namespace. Development signing uses the stable
neutral subject `CN=Android Development,O=Workspace Development`; signing
identity is a build credential, not product identity.

### Static packaging templates

The only static identity placeholder syntax is
`${PRODUCT_IDENTITY.<typed-member>}`. It is valid only in files declared in the
generator manifest. The generator understands and validates the destination
format rather than performing unconstrained textual replacement.

The rendered set includes desktop files, icon aliases, D-Bus service files,
systemd units, portal files, Android properties and manifests, launchers, and
install manifests. Binary icon content is identity-neutral; generated aliases
and metadata provide its configured application ID. Build recipes consume only
rendered outputs and never substitute identity themselves.

## Generated identity boundary

Create `product.json` at the repository root,
`tools/product-contracts.json` as the neutral contract catalog, and
`tools/generate-product-identity.py` as the single generator. The generator uses
only the Python standard library and runs before any SwiftPM manifest is
evaluated. Python 3 becomes an explicit setup prerequisite.

The generator writes:

- `foundation/Sources/ProductIdentity/GeneratedIdentity.swift`
- `foundation/Sources/ProductIdentityC/include/GeneratedProductIdentity.h`
- `tools/generated/product-identity.sh`
- `generated/product-identity/android.properties`
- static package files rendered from checked-in templates under
  `generated/product-identity/packages/`
- `generated/product-identity/fingerprint.json`, containing the input digest,
  generator digest, schema version, and output digests

The C header exposes one neutral `static inline const char *` accessor per typed
contract. It exports no storage or linkable symbol and uses a neutral include
guard. The shell output assigns read-only neutral variable names; it never
constructs suffixes at a call site. Android properties use neutral fixed keys.

All outputs are ignored build products. Templates contain typed placeholders,
not default identity values. The generator writes atomically and fails if an
unknown placeholder or unused identity field remains.

Generation holds an advisory lock under `.workspace-tool-bootstrap/`, writes a
complete generation beside the old one, verifies every
output digest, and atomically exchanges the generation directory. Concurrent
callers either reuse the matching fingerprint or wait for the writer. A new
generation removes outputs that disappeared from the generator manifest.
Interrupted generation never replaces the last complete generation.

The ignored repository-local `.workspace-tool-bootstrap/` directory is the only
identity-independent mutable state. It contains the generator lock and the
installation ownership receipt so a changed `name` or `toolName` can safely
supersede the prior launcher. It contains no build products, caches, logs,
configuration, or runtime state.

`collider-setup.sh` and `tools/host-env.sh` run the generator before sourcing the
generated shell file. The installed workspace tool runs the same freshness
check before bootstrap, build, or test work. A direct build after sourcing
`tools/host-env.sh` therefore observes the same identity as the installed tool.

`workspace-setup.sh`, after its phase 2 rename, performs the same operation.
Cleaning generated identity removes only outputs listed in the fingerprint
manifest. It does not clear SwiftPM, native SDK, download, or build caches.

SwiftPM package names, library products, executable products, and target names
are neutral internal build identifiers. They do not vary when `product.json`
changes. The neutral executable product is installed on `PATH` under
`toolName`; changing `toolName` does not mutate the SwiftPM graph.

Create two leaf targets:

- `ProductIdentity`, containing the generated values and pure Swift derivation
  APIs
- `ProductIdentityC`, exposing generated C string constants only to C-family
  targets that read product-owned contracts

Only consumers of identity depend on these targets. Generic libraries receive
resolved paths or names from their caller instead of acquiring a global
dependency.

The generated Swift and C surfaces expose the same schema version and identity
fingerprint. Every deployable first-party executable embeds that fingerprint in
its build metadata. Static packages record it in their generated manifest.
Composition roots validate child executable and dynamic-library fingerprints
before launch and report a rebuild requirement on mismatch. Mixed-identity
process trees are never started.

Installation uses an explicit setup `--prefix`, defaulting to `~/.local`.
The payload path is
`<prefix>/libexec/workspace-tool/<identity-fingerprint>/WorkspaceTool` and the
launcher is `<prefix>/bin/<toolName>`. Installation writes its ownership receipt
both beside the versioned neutral payload and in
`.workspace-tool-bootstrap/`. A launcher update is atomic. When `toolName`
changes, setup removes the preceding launcher only when both receipts prove
that the same checkout installed it and its content digest still matches.
Unknown or modified files are never overwritten or removed. Help, diagnostics,
and examples use the configured `toolName`; behavior never depends on `argv[0]`.

## Runtime identity API

`ProductIdentity` is an immutable value. The generated file exports
`ProductIdentity.configured`; tests and tools may construct other values.

Runtime path resolution is separate from the five declared fields:

- `cacheRoot(environment:userHome:)` returns
  `$XDG_CACHE_HOME/<name>` or `<home>/.cache/<name>`
- `configRoot(environment:userHome:)` returns
  `$XDG_CONFIG_HOME/<name>` or `<home>/.config/<name>`
- `workspaceStateRoot(workspace:)` returns `<workspace>/.<name>`
- `nativeSDKRoot(environment:userHome:)` derives from `cacheRoot`
- `sessionRuntimeDirectory(parent:sessionID:)` returns
  `<parent>/<name>-<sessionID>`
- `controlSocket(sessionRuntimeDirectory:)` returns
  `<session-runtime>/control.sock`

The generated typed contract members use private derivation primitives for
environment variables, D-Bus names, desktop IDs, Android namespaces, and metric
names. Callers cannot pass arbitrary suffixes.

The user runtime root and private session runtime directory remain different
types. Once a session starts, its private directory becomes the child
processes' `XDG_RUNTIME_DIR`. Code must not append the product name to that
already-private directory.

The private Wayland display remains the protocol-domain value `wayland-0`.
Isolation comes from the private session runtime directory, so product branding
does not improve its uniqueness.

All filesystem resolvers accept explicit environment and home inputs. Production
callers pass the process environment; tests use dictionaries and temporary
directories without mutating process-global state.

## Measured baseline

Before phase 1, add `tools/audit-product-identity.py` and record a machine-readable
baseline under the workspace state root. The audit excludes:

- `.build/`, `out/`, and generated workspace state
- `.workspace-tool-bootstrap/`
- `third-party/` and all other upstream submodules
- `swift-toolchain/`
- `android-runtime/.aosp-source/`
- `node_modules/`
- `.git/`

The baseline records:

- authored occurrences of every configured identity field and its case variants
- branded SwiftPM packages, products, targets, and dependencies
- branded Swift modules, imports, SPI groups, declarations, and symbols
- C-family symbols and include guards
- product-owned environment-variable read and write sites
- paths, command-line flags, telemetry keys, protocol identifiers, and
  user-visible strings
- branded files and directories
- generated-code producers and their outputs
- the complete SwiftPM target inventory and test-target inventory
- executed test and suite identifiers, not only aggregate counts

The audit parses JSON, SwiftPM manifest descriptions, generator manifests, and
known static packaging formats. Regex counts are supplemental diagnostics, not
completion evidence.

For each configured or forbidden value, the audit checks the original spelling,
ASCII case variants, upper-snake form, lower-kebab form, Swift/Java
UpperCamel form, C symbol prefix form, reverse-DNS components, and filesystem
slug form. It scans authored text, generated text, archive members, package
manifests, demangled and raw symbol tables, binary string tables, debug
information, source maps, logs, and installed metadata. It unpacks first-party
archives and compressed packages before scanning.

Debug paths are evaluated only from a neutral checkout path. Findings in
excluded upstream inputs or linked upstream artifacts are accepted only when an
`upstream` ownership entry names the source dependency, source path, output
artifact, and expected transformed spelling. The audit has no generic substring,
directory, binary, or third-party allowlist.

The neutral final package, product, target, test-target, test, and suite
inventories are checked in under `tools/verification/` as the lasting
verification baseline. The checked-in upstream provenance catalog lives there
as well. These files contain neutral identities and dependency provenance, never
configured product values. Migration-only ownership and neutralization maps are
removed with this document after the final inventory is established.

## Phase 1 — Establish the identity pipeline

Add `product.json`, schema validation, the generator, generated-output
fingerprints, the Swift and C identity targets, and behavioral tests.

Generate and validate the complete ownership classification, typed contract
catalog, neutralization map, final package/target inventory, and final
filesystem inventory before changing an existing name. Resolve all collisions
under the fixed naming grammar in these generated plans; phase 2 does not begin
while any occurrence lacks a destination or ownership class.

Tests construct an unrelated identity fixture and assert composition from that
fixture. They never compare a configured field with a hardcoded default value.
Path tests pass explicit environment and home values and cover XDG overrides,
fallbacks, invalid session IDs, and socket-length rejection.

Update setup and host-environment entry points to generate and verify identity
before evaluating SwiftPM manifests. A stale or partially generated identity is
a hard failure.

**Gate:** generator determinism, schema validation, stale-output detection,
complete collision-free migration manifests, and all `ProductIdentity`
behavioral tests pass from a fresh checkout with no generated identity files
present.

## Phase 2 — Neutralize and route the workspace tool

Treat all `Collider` and `collider` names as branding.

Rename the implementation by domain:

- `collider/` becomes `build-tool/`
- `collider-setup.sh` becomes `workspace-setup.sh`
- the CLI package becomes `workspace-tool`
- `collider/engine/` becomes `build-tool/engine/`
- the engine package becomes `build-engine`
- `ColliderCore` becomes `BuildCore`
- `ColliderRuntime` becomes `BuildRuntime`
- `ColliderCommands` becomes `WorkspaceCommands`
- the executable target and product become `WorkspaceTool`
- recipe modules apply the fixed `<Domain>BuildRecipe` mapping, including
  `CoreBuildRecipe`, `CompositorBuildRecipe`, and `AndroidRuntimeBuildRecipe`
- remaining `Collider…` types, fixtures, resource paths, C symbols, include
  guards, comments, and diagnostics take their owning build domain's name

The installed executable name, launcher path, help invocation, and
documentation command derive from `toolName`. Product-owned `COLLIDER_*`
environment variables move to their named `identity.environment` contracts;
generic build-engine configuration becomes typed arguments and no longer uses
branded environment variables.

Setup invokes the neutral SwiftPM executable product and installs it under the
generated tool name. The build engine never discovers its own installed name
from module, target, executable, or directory names.

**Gate:** setup, doctor, bootstrap, build, and test commands work through a
generated launcher. The audit reports no authored `Collider`/`collider`
branding outside this migration document and `product.json`.

## Phase 3 — Route environment contracts

Inventory product-owned variables by their read and write sites: Swift
environment dictionaries, `getenv`, `setenv`, shell parameter expansion,
systemd `Environment=`, Gradle environment access, and C-family APIs.

Move each product-owned variable to its named member in
`identity.environment` or the generated C and shell equivalent. Replace
environment transport with typed arguments where the value is internal to one
process tree. Preserve specification-owned names such as `XDG_*`,
`WAYLAND_DISPLAY`, `DISPLAY`, and `SSH_AUTH_SOCK`.

Environment renames land atomically across launchers, services, test fixtures,
and readers. No compatibility aliases remain.

**Gate:** the audit finds no authored configured prefix or retired tool prefix
at an environment-variable access site. Session, Android presentation,
sanitizer, benchmark, and fixture tests pass.

## Phase 4 — Route filesystem identity

Replace branded path construction with the typed runtime identity API:

- user cache and configuration roots
- native SDK roots
- repository-local workspace state
- build output and staging roots
- run and log directories
- session runtime directories
- control and fixture sockets
- generated metadata and ownership marker files

Keep domain-only filenames such as `control.sock`, `environment.sh`, and
`source-provenance.json` when their parent already provides isolation. Do not
repeat the product name in both a directory and every child filename.

Callers that operate inside a private `XDG_RUNTIME_DIR` use it directly.
Callers that begin with the user's runtime root explicitly construct a session
runtime directory once.

**Gate:** cold bootstrap and all path/security tests pass under both default and
custom XDG roots. The audit finds no authored product or tool branding in a path
expression.

## Phase 5 — Route protocols, packaging, Android, and telemetry

Route every externally observed static or runtime identifier:

- D-Bus owned names, interfaces, object-related error names, and test names
- desktop-file IDs, icon IDs, MIME associations, and application IDs
- systemd unit names and environment entries
- portal service files, backend IDs, filenames, and `UseIn=` values
- `XDG_CURRENT_DESKTOP`
- Android namespaces, application IDs, Maven coordinates, generated bindings,
  Java/Kotlin public package façades, JNI lookup names, and signing subjects
- tracing labels, metric keys, queue labels, and diagnostic namespaces
- command-line flags whose spelling contains product or tool branding

Retire `org.<product>` and route all owned reverse-DNS names directly through
the configured namespace. Do not first rewrite them to another literal.
Specification-owned namespaces, including `org.freedesktop.*`, remain literal.

Kotlin uses the fixed private implementation package and generated public façade
defined above. Swift-Java and `RegisterNatives` consume the same generated
Android contract. Gradle reads generated Android properties. Packaging recipes
consume rendered static files rather than copying authored branded files.

**Gate:** private-bus D-Bus and AT-SPI tests, session packaging tests, Android
build/codegen tests, telemetry tests, and static-package validation pass. The
audit accounts for every configured reverse-DNS occurrence as a generated
output.

## Phase 6 — Route user-visible identity

Window titles, application labels, about text, help text, log banners, error
messages, and other product-facing strings use `displayName`, `name`, or
`toolName` according to their contract. Localized strings retain stable neutral
keys and substitute identity at formatting time.

Diagnostics describe the failing domain. They do not prepend the product name
unless the surrounding user interface requires product identification.

**Gate:** behavioral snapshots rendered with an unrelated identity contain the
fixture display and tool names and contain none of the default identity.

## Phase 7 — Neutralize C-family symbols and guards

Rename branded C and C++ symbols by owning domain. For example,
`nucleus_secure_zero` becomes `secure_memory_zero`, while a D-Bus shim function
uses a sufficiently specific `dbus_shim_` prefix.

Rename branded include guards by header domain. Rename generated declarations
at their generator. Rename branded namespaces, JNI bridge entry points, library
sonames, linker export lists, and symbol lookup strings in the same phase.

`static inline` functions need no linkage prefix. Non-inline functions retain a
domain prefix specific enough to avoid collisions with system libraries. All
cross-language non-inline declarations keep `extern "C"` guards, and entry
points into throwing C++ remain `noexcept` with internal exception handling.

**Gate:** full build and suite pass; symbol-table inspection and the audit find
no branded first-party C/C++/JNI symbol or include guard.

## Phase 8 — Neutralize SPI groups

Rename branded SPI groups by capability:

- `NucleusCompositor` becomes `Compositor`
- `NucleusPlatform` becomes `Platform`
- `NucleusRenderServer` becomes `RenderServer`
- `NucleusShellTesting` becomes `ShellTesting`
- `NucleusWindowClientImplementation` becomes
  `WindowClientImplementation`

Update every declaration and import together.

**Gate:** full build passes and the audit finds no branded SPI group.

## Phase 9 — Neutralize SwiftPM and Swift names

Rename packages, products, targets, modules, declarations, imports,
testable imports, test targets, executable lookup strings, and generated-code
producers in dependency order.

Apply the frozen neutralization map and naming grammar. Standalone generic names
are prohibited because they collide with platform modules or communicate too
little; no phase-local naming decisions are permitted.

Explicit SwiftPM `path:` declarations keep existing directories in place during
this phase. Each dependency layer lands with all of its imports and manifest
references, then builds before the next layer.

Generated code changes at its generator. No generated output is edited.

**Gate:** full build and suite pass. The SwiftPM package, product, target, and
test-target inventories match the baseline one-for-one after applying the
checked rename map. Executed test and suite identifiers show no missing target.

## Phase 10 — Neutralize the filesystem tree

Move source, test, fixture, resource, and package directories to their neutral
module or domain names. Update explicit SwiftPM paths, Gradle source sets,
codegen inputs, resource lookups, scripts, and build recipes with each move.

Then rename ordinary files whose names contain product or tool branding.
Platform selector suffixes in the React Native library become a neutral
platform-domain suffix, and Metro resolution/codegen is updated at its source.

Directory moves are separate from module renames so SwiftPM's explicit paths
make omissions visible and reviewable. After every package move, compare its
declared target and test inventory with the phase 9 inventory.

**Gate:** full build and suite pass with identical package, target, test-target,
test, and suite inventories. The filesystem audit finds no first-party branded
file or directory.

## Phase 11 — Rewrite static text and documentation

Rewrite shell, JSON, TOML, Gradle, XML, YAML, comments, READMEs, and maintained
documentation around neutral internal names and generated user-facing identity.
Examples either interpolate generated identity or use clearly unrelated
fixtures.

Rewrite `AGENTS.md` last because it names the final package, module, tool, and
directory architecture.

Encode the lasting rules and all completion checks in
`tools/audit-product-identity.py`. Keep this migration document and its generated
migration maps until phase 12 completes.

**Gate:** the authored-tree audit reports zero unaccounted configured product or
tool identity occurrences outside `product.json` and this migration document.

## Phase 12 — Prove arbitrary renaming

Run the rename qualification in a temporary copy located under a neutral path,
so debug information cannot inherit branding from the checkout directory.

The qualification:

1. Records the original five identity values as the forbidden set.
2. Replaces all five fields with unrelated, schema-valid values.
3. Deletes only generated identity outputs in the temporary copy.
4. Runs setup, doctor, cold bootstrap, full build, and the full suite through the
   newly generated installed tool name.
5. Exercises session startup logic, D-Bus ownership, static packaging, Android
   codegen, control-socket discovery, desktop identity, and user-visible
   snapshots without launching an interactive compositor.
6. Inspects generated files, installed packages, executable string tables,
   exported symbols, module metadata, manifests, logs, and runtime probe output
   for every forbidden value and case variant.
7. Compares package, target, test-target, executed test, and suite inventories
   with the pre-rename baseline.
8. Promotes the final neutral inventories and upstream provenance to
   `tools/verification/`, removes the migration-only ownership and
   neutralization maps, removes this migration document, and reruns the
   authored-tree audit.

Third-party artifact findings are accepted only through a checked provenance
allowlist naming the upstream input and artifact. First-party exceptions are
not allowed.

**Gate:** every qualification step passes, every expected artifact contains the
alternate identity where appropriate, no first-party artifact contains a
forbidden original value, and all inventories match.

## Permanent verification

The following checks remain part of the normal complete-checkout verification:

- identity schema validation
- deterministic generation and fingerprint validation
- authored identity audit
- neutral package/module/symbol/filesystem audit
- generated static-package validation
- package, target, and test-target inventory comparison
- full behavioral suite
- alternate-identity qualification

Aggregate test counts remain diagnostic. Target identities and executed
test/suite inventories are the authority, because a missing test target can
produce a successful run with a lower count.

## Exclusions

- Do not rename or patch vendored and upstream trees solely for this migration.
- Do not edit generated output; change the generator or template.
- Do not create compatibility aliases, dual environment variables, legacy
  launchers, or deprecated module wrappers.
- Do not rewrite specification-owned identifiers such as `XDG_*`,
  `WAYLAND_DISPLAY`, `org.freedesktop.*`, or upstream Android/React Native names.
- Do not derive internal module, target, package, directory, or symbol names from
  runtime product identity.
- Do not use generic neutral names that collide with platform modules.
- Do not clear complete build caches to mask stale identity generation.
- Do not accept aggregate test counts without matching target and suite
  inventories.
