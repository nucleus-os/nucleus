# Product Identity and Naming Boundaries

## Invariant

Nucleus keeps branding where it is part of a deliberate user, source, package,
or platform contract. Implementation names are neutral when the brand adds no
meaning, and shared product strings and paths are never reconstructed at their
call sites.

The migration does not make the repository generically rebrandable and does not
rename every `Nucleus` or `Collider` occurrence. It establishes one authored
definition for each deployable product name, executable basename, external
identifier, and owned filesystem leaf, then makes every producer and consumer
use that definition. A future product rename is consequently a bounded contract
change, not a search-and-replace exercise.

## Naming boundary

Every name belongs to one of these classes before it changes.

| Class | Treatment | Current examples |
|---|---|---|
| Supported Swift source API | Keep intentional branding and Swift naming | `Nucleus`, `NucleusDesktop`, `NucleusReactRuntime`, `NucleusFoundation`, `NucleusSessionProtocol`, `NucleusAndroidRuntimeCore` |
| Other source or binary contract | Keep or rename only through an explicit API/ABI migration | `NucleusConfig`, `NucleusControlProtocol`, `dev.nucleus.android`, `libnucleus-android.so` |
| User-facing product identity | Keep the branded spelling, but obtain it from the identity catalog | `Nucleus`, the `nucleus` control command, desktop and accessibility application names |
| Installed component identity | Centralize exact basenames and relative install locations | `NucleusCompositor`, `NucleusShell`, `NucleusSessionSupervisor`, `nucleus-session`, systemd units, `share/nucleus` |
| Developer-tool identity | Keep as its own intentional product contract | `collider`, `collider-setup.sh`, `ColliderCLI`, `ColliderWorkspaceCommands`, `ColliderLinuxOperations` |
| Internal implementation name | Prefer a domain name when touching or moving the declaration | process, storage, transport, parsing, staging, and lifecycle helpers |
| Specification or upstream name | Preserve exactly | XDG variables, D-Bus and Wayland names, Vulkan names, upstream paths and artifacts |

Branding is not inherently an implementation leak. A branded module, product,
or top-level type is appropriate when it gives Swift clients a clear namespace
and communicates which framework owns the API. Swift-facing APIs use normal
Swift conventions: branded modules/products provide the namespace; declarations
inside them do not repeat `Nucleus` unless the repeated prefix prevents ambiguity
for a real consumer. Public spelling changes only when the resulting API is
materially clearer and all supported consumers are migrated in the same change.

Conversely, generic code does not acquire a product prefix merely to establish
ownership. Names such as `RuntimeInstallation`, `ConfigurationServiceState`,
`SessionCapability`, and `DirectoryLifecycle` already communicate their domain.
New internal types follow that pattern. Existing internal prefixes are removed
only as part of coherent subsystem work, with compiler-checked caller updates;
there is no repository-wide mechanical neutralization pass.

## Identity model

Add a small checked-in product identity catalog at the repository root. It is
the authored source for deployable identity, not for Swift declaration names or
repository topology. It contains typed, independent fields rather than deriving
one spelling by case conversion:

```json
{
  "displayName": "Nucleus",
  "filesystemName": "nucleus",
  "reverseDNSName": "dev.nucleus",
  "environmentPrefix": "NUCLEUS",
  "commands": {
    "control": "nucleus",
    "session": "nucleus-session",
    "sessionValidator": "nucleus-session-validate"
  },
  "services": {
    "compositor": "NucleusCompositor",
    "shell": "NucleusShell",
    "sessionSupervisor": "NucleusSessionSupervisor",
    "configuration": "NucleusConfigService",
    "control": "NucleusControlService",
    "pamHelper": "NucleusShellPamHelper"
  }
}
```

The final catalog includes the Android runtime helpers and every other shipped
executable. Names are explicit because capitalization and historical spelling
are contract decisions, not reliable transforms. Validation rejects empty
values, path separators, invalid reverse-DNS/environment forms, duplicate
installed basenames, and relative paths disguised as names.

`collider` remains separate from the runtime product identity. It is the named
developer workflow for this repository, not a configurable launcher for a
white-label product. Collider may consume the runtime catalog when it builds,
installs, launches, or validates Nucleus, but its own command, package, module,
cache, and lock names remain Collider contracts. This prevents product identity
work from turning into a build-engine rename.

## Generated and typed access

A deterministic generator validates the catalog and emits only the forms needed
by each build system:

- a package-visible Swift identity API for first-party runtime targets;
- a Collider-side Swift identity API for recipes, installation, run, doctor,
  profiling, and tests;
- Android/Gradle constants for namespace, artifact, native-library, and asset
  names where those contracts are selected for centralization;
- rendered packaging metadata for systemd, desktop, D-Bus, portal, and launcher
  files.

Generated files are checked in when SwiftPM or Gradle must evaluate them before
a generator can run. A verification command regenerates them into a temporary
location and fails on differences. No runtime process parses the JSON catalog.

Swift consumers use named members grouped by role, such as
`ProductIdentity.displayName`, `ProductIdentity.Command.control`, and
`ProductIdentity.Service.compositor`. They do not accept arbitrary suffixes or
perform case conversion. Libraries that do not need product identity receive a
resolved value through their existing configuration or initializer boundary
instead of importing the catalog.

`Package.swift` reads the validated generated manifest values needed for product
names, or uses generated Swift manifest declarations included directly by the
manifest. Swift target and module names remain literal where they form source
identity. The root package therefore centralizes executable product spelling
without making supported module names configurable.

## Filesystem ownership

The catalog supplies stable leaf names; a typed path policy owns how those names
are placed on each platform. Call sites request a semantic location and never
append `nucleus`, `.nucleus`, `share/nucleus`, or an executable basename
themselves.

The path policy distinguishes these roots:

| Root | Linux policy | Ownership |
|---|---|---|
| User configuration | `$XDG_CONFIG_HOME/<filesystemName>`, else `$HOME/.config/<filesystemName>` | persistent, user-authored |
| User data | `$XDG_DATA_HOME/<filesystemName>`, else `$HOME/.local/share/<filesystemName>` | persistent, product-owned |
| User state | `$XDG_STATE_HOME/<filesystemName>`, else `$HOME/.local/state/<filesystemName>` | persistent operational state and logs |
| User cache | `$XDG_CACHE_HOME/<filesystemName>`, else `$HOME/.cache/<filesystemName>` | disposable derived data |
| Session runtime | a product/session child of `$XDG_RUNTIME_DIR` | ephemeral sockets and runtime state |
| Repository state | `<repository>/.<filesystemName>` | disposable or generated checkout-local state |
| Installation share | `<prefix>/share/<filesystemName>` | immutable installed metadata |
| Installation executables | catalogued paths below `<prefix>/bin` and `<prefix>/libexec` | immutable installed payload |

On Apple platforms the same semantic requests resolve through the appropriate
Foundation directory APIs and append the catalogued product leaf. Platform
policy is not encoded as Linux path strings in shared libraries.

The policy exposes concrete domain paths such as the configuration file,
runtime installation metadata, session capability directory, SwiftPM scratch
root, native SDK cache, and capture/log roots. It does not expose a generic
`path(suffix:)` escape hatch. Shared upstream downloads may remain in a neutral,
content-addressed cache when they truly have no product-specific semantics.

Changing a name does not silently merge old and new state. Persisted user data
gets a deliberate one-time hard migration or reset at the point of the rename.
Caches and checkout-local generated state reset. Runtime state never migrates.
No compatibility readers, aliases, or dual-write paths are added unless an
independently deployed boundary demonstrably requires them.

## Contracts that remain branded

The following are not neutralization targets merely because they contain the
product name:

- supported Swift products and the modules and public types through which their
  APIs are naturally discovered;
- executable and library filenames used by packaging, launchers, dynamic
  loading, JNI, PAM, systemd, or test harnesses;
- Android package, Maven, JNI, and native-library names until an explicit Android
  distribution migration is undertaken;
- environment variables, command-line flags, D-Bus names, desktop IDs, service
  names, metrics, and persisted keys that are already external contracts;
- source paths required by AOSP, upstream repositories, generated code, or other
  build systems;
- the Collider command and its Swift package/module family.

These contracts still use one source of truth where multiple producers need the
same spelling. Centralization does not imply configurability, and configurability
does not imply compatibility with arbitrary rebranding.

Protocol-local names remain neutral when their enclosing boundary already makes
them unambiguous: `control.sock`, `wayland-0`, `environment.sh`, file-descriptor
roles, packet fields, and operation names do not need a product prefix. Internal
same-build protocols do not gain identity versions or magic values as part of
this work.

## Sequential implementation plan

### Phase 1: Inventory and classify the live contracts

Build a focused inventory from the root `Package.swift`, Collider recipes and
commands, runtime installer, session packaging, configuration lookup, Android
Gradle/JNI surface, environment access, and XDG/path construction. Record each
shared occurrence as source API, external runtime contract, installed component,
filesystem leaf, developer-tool identity, internal implementation, specification,
or upstream value.

The inventory is a migration aid, not a permanent exhaustive allowlist. It
identifies actual duplicate ownership and the consumers that must move together.
Tests and fixtures are classified by the production contract they exercise.

### Phase 2: Establish the catalog and generated accessors

Add the validated catalog, deterministic generator, generated Swift/Gradle
inputs, and drift verification. Populate it with the current spellings so this
phase changes ownership without changing external behavior.

Make the root manifest derive shipped executable product names from the generated
manifest input. Keep target/module names and supported library product names
intentional and explicit. Give Collider its generated view without introducing a
dependency from the generic `ColliderCore`/`ColliderRuntime` engine onto Nucleus
identity.

### Phase 3: Centralize installation and launch identity

Replace the repeated executable and relative install paths in
`RuntimeInstallation`, runtime staging, ELF validation, session capability
generation, run, doctor, sanitizer, benchmarks, and recipe product lookup with
typed catalog members. Generate systemd and launcher metadata from those same
members and validate rendered files before publication.

The installed tree has one typed layout description used for staging,
validation, discovery, and launch. No consumer reconstructs a path from an
assumed product basename.

### Phase 4: Centralize configuration, data, cache, state, and runtime paths

Introduce the platform path policy and migrate `ConfigFile` first, preserving
`$XDG_CONFIG_HOME/nucleus/config.json` and its fallback exactly. Then migrate
checkout state, native SDK/cache roots, profiles and logs, runtime directories,
session sockets, and installed shared data by semantic group.

Delete superseded local constants and ad hoc XDG fallback logic as each group
lands. Preserve third-party search paths such as icon-theme and desktop-file
lookup when they describe the freedesktop environment rather than Nucleus-owned
storage.

### Phase 5: Centralize external identifiers that genuinely share identity

Move user-visible display strings, accessibility application identity,
product-owned environment keys, desktop/D-Bus/systemd identifiers, and selected
Android build constants onto typed generated values. Keep protocol roles and
domain vocabulary neutral. Keep public Swift and Android spellings branded where
they are the idiomatic consumer-facing namespace.

Any external spelling change is a separate deliberate migration within this
phase, with all producers, consumers, packaging, and behavioral tests updated in
one change. The centralization itself preserves spelling.

### Phase 6: Remove incidental internal branding

After shared identity is centralized, rename internal declarations whose product
prefix adds no information and whose callers are wholly first-party. Do this by
subsystem so the compiler checks the complete move. Do not rename repository
roots, Swift modules, products, C symbol families, Android packages, or generated
bindings simply to reduce textual matches.

Delete obsolete constants, wrappers, and duplicate path builders. Finish with a
targeted audit that every remaining authored product string is either the
catalog, a deliberate source/external contract, a specification value, or an
upstream occurrence.

## Verification

Each phase adds behavioral checks at the owning boundary:

- catalog validation and generated-output drift checks;
- manifest assertions that catalogued executable products map to the intended
  targets;
- installation tests proving the staged, validated, published, and discovered
  trees use the same layout;
- path-policy tests for set, empty, and absent XDG variables and for Apple
  Foundation resolution;
- configuration tests preserving the current default location and missing-file
  behavior;
- packaging validation for systemd, desktop, D-Bus, portal, Android, and dynamic
  library references that are in scope;
- runtime contract tests for launch arguments, environment keys, sockets, and
  capability declarations;
- public-source consumer builds for every supported external Swift product.

Tests assert resolved values and behavior, not the presence or absence of source
declarations. The final textual audit is diagnostic: it catches new duplicate
literals but does not declare branded APIs incorrect merely because their names
contain `Nucleus` or `Collider`.

## Completion criteria

The work is complete when shipped executable names and installed relative paths
have one typed owner; owned config, data, state, cache, runtime, repository, and
installation paths flow through the platform path policy; generated consumers
cannot drift from the checked-in catalog; supported branded APIs remain intact;
and remaining internal branding is either useful domain ownership or a recorded
external/build-system constraint.

Completion does not require a brand-free source tree, a repository rename, a
generic white-label build, or preservation of old paths after a future rename.
