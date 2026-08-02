# Configuration system

**Invariant: one configuration service owns the user-edited JSON document, validates it into `NucleusConfiguration`, and publishes typed projections to the render server and shell. Runtime processes never parse competing configuration formats or read the configuration file independently.**

## Authority and ownership

- `config/model/Sources/NucleusConfig` owns the resolved model, defaults, validation, and projection types.
- `config/Sources/NucleusConfigSyntax` prepares JSON and reports source locations.
- `config/Sources/NucleusConfigIO` owns file loading, decoding, diagnostics, and export.
- `config/config-service-core` owns the active generation and publication lifecycle.
- `NucleusSessionProtocol` carries `RenderServerConfiguration` and `ShellConfiguration` publications over dedicated session channels.
- The render server owns input, binds, and output policy. The shell owns shell appearance and product preferences. Neither receives fields it does not own.

The configuration language is JSON with snake-case keys. KDL and TOML are not supported configuration paths. App-local `nucleus.config.json` files are a different boundary: they configure an individual Nucleus application and do not replace the desktop configuration service.

## Runtime contract

The service loads built-in defaults, applies the optional user document, validates the resolved value, and publishes an epoch and monotonically increasing generation. A successful reload atomically replaces the complete active generation. A failed reload preserves the last valid generation and publishes diagnostics.

Subscribers request their role-specific projection. They apply a publication as one value and acknowledge the generation through the session control contract. Filesystem access, syntax handling, migration, and write coordination remain outside subscriber processes.

Unknown keys produce warnings because silently accepting a typo is unsafe. Invalid types, invalid values, and malformed JSON reject the candidate generation. Array fields whose semantics are replacement remain whole-value replacements.

## Evolution

The persisted user document is the only boundary here that can outlive the producing build. `config_version` therefore belongs to the file model and drives one-way migrations when the shape changes. Internal projection and channel payloads ship from the same monorepo build and do not acquire independent schema versions.

Configuration changes land in this order:

1. Extend the resolved and partial model, defaults, validation, and projection ownership.
2. Add loader, exporter, migration, and diagnostic coverage.
3. Add service publication coverage for the affected projection.
4. Apply the typed value in the owning runtime process.
5. Update the user schema and configuration documentation.

## Remaining work

1. Add atomic on-disk writes and preserve permissions when the service gains mutation APIs.
2. Add directory-level file watching so editor rename-and-replace saves trigger reloads.
3. Add explicit migrations when the first persisted shape change is required.
4. Surface structured diagnostics in the shell while retaining stderr logging for headless sessions.
