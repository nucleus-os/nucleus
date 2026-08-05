# Visibility and native-link qualification plan

Status: active.

## Invariant

Swift visibility follows the supported consumer boundary. `public` serves the
six supported external source products. First-party cross-module API is
`package`; implementation detail is `internal` or narrower. Dynamic linkage is
not evidence of a public source contract. First-party SPI requires an actual
external-package production consumer.

The visibility migration and external consumer fixtures are implemented. This
plan owns only the remaining native and whole-graph verification.

## Phase 1 — Rebuild external consumers from clean derived state

Build every package under `integration-tests/public-source-contracts` against
the root package using the selected Xcode compiler and no root testability.
Verify that each client imports only its supported product and that unsupported
implementation modules remain inaccessible through ordinary imports.

Gate: every supported external source product compiles independently and no
client relies on first-party package visibility or testability.

## Phase 2 — Qualify native link boundaries

Run the complete root build and test graph, sanitizer harnesses, dynamic-library
resolution checks, Android packaging, and both Linux runtime link validations.
Verify C/C++ linkage names, `noexcept` containment, opaque-handle ownership, and
libc++ closure at the actual executable and dynamic-library boundaries.

Gate: every shipped product links and loads with only its declared native SDK
artifacts and no external consumer requires an undeclared Swift symbol.

## Phase 3 — Close the migration

Move any newly discovered durable visibility rule into the root architecture
contract and remove this qualification plan.
