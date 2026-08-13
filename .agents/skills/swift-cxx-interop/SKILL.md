---
name: swift-cxx-interop
description: Design, implement, review, and debug bidirectional Swift/C++ interoperability. Use for SwiftPM targets with C++ interoperability, Clang modules and module maps, C++ APIs imported into Swift, Swift APIs exposed through generated C++ headers, swift/bridging annotations, C++ value/reference ownership and lifetimes, containers, std::function callbacks, exception boundaries, or mixed Swift/C++ compiler and linker failures.
---

# Swift/C++ Interoperability

Use the vendored official Swift.org guide as the authority for language mappings and supported interop behavior. Keep it out of context until the task's topic is known, then load only the relevant section.

## Route the task

1. Read [references/topic-index.md](references/topic-index.md).
2. Select the narrowest relevant line range in `references/mixing-swift-and-cxx.md`.
3. Read adjacent sections when ownership, lifetime, copying, or generated-header behavior crosses the selected boundary.
4. For current support status or build-system limitations, follow the official live links in the topic index. These evolve independently from the vendored guide.
5. Inspect the actual declarations, module map or umbrella header, `Package.swift` settings, generated interface, build command, and full diagnostic before proposing a change.

## Apply the repository contract

Treat the repository's `AGENTS.md` as an additional contract. In Nucleus specifically:

- Keep first-party C++ libraries behind SwiftPM C/C++ targets and Clang module maps.
- Use C++ interop directly; do not introduce an alternative non-C++ target tier.
- Keep C++ types out of Swift domain models. Carry opaque handles, scalars, and value structs at architectural boundaries.
- Model Swift-to-C++ callbacks with a `std::function` typedef and a thick Swift closure when Swift owns the seam end to end.
- Drop replaced or cleared `std::function` values outside locks because destroying their Swift captures can re-enter the seam.
- Reserve `@convention(c)` trampolines for external C APIs that require function pointers and context pointers.
- Wrap non-inline functions declared by first-party C headers in `extern "C"` guards because every Swift target parses C headers in C++ mode.
- Make every entry point into potentially throwing C++ code `noexcept` and catch internally; Swift cannot catch a C++ exception.

## Design the boundary

State these facts explicitly before editing:

- Which direction crosses the boundary: Swift calling C++, C++ calling Swift, or both.
- Which target owns each declaration and which generated or handwritten header makes it visible.
- Whether every transferred type is a value, borrowed view, uniquely owned value, shared reference, immortal reference, or unsafe reference.
- Which object owns each pointer, reference, view, iterator, callback capture, and returned buffer, and how long that owner stays alive.
- Whether a call can throw, block, invoke callbacks synchronously, or destroy captures during replacement or teardown.
- Whether copying a C++ value or container is semantically correct and acceptable for the hot path.

Choose the simplest representation whose ownership is explicit. Prefer values for small self-contained data, scoped borrowing for dependent data, `std::function` for owned callbacks, and annotated reference types only when the C++ object genuinely has reference identity.

## Implement and verify

1. Make the C++ declaration importable and give it accurate constness, move/copy behavior, nullability, exception behavior, and lifetime annotations.
2. Expose it through the target's public header/module map or through the generated Swift-to-C++ header as appropriate.
3. Inspect the imported or generated interface rather than guessing Swift or C++ spellings.
4. Add a narrow Swift or C++ façade when the raw imported API exposes dependent lifetime, unsafe iteration, unsuitable naming, or unsupported types.
5. Test runtime behavior: construction, copy/move, callback invocation, replacement, teardown, and error paths. Do not test declaration shape.
6. Format touched Swift with the pinned `swift-format` and run the narrowest relevant Collider build/test gate, widening only when dependency impact requires it.

## Diagnose failures

- Import failure: verify `.interoperabilityMode(.Cxx)`, dependency propagation, public header placement, umbrella header/module map contents, header self-containment, and C++ parsing compatibility.
- Undefined symbol with a demangled C function signature: check missing `extern "C"` guards before changing linker inputs.
- Missing or unavailable Swift API in C++: inspect the generated header and confirm every parameter/return type is representable and the API is public at the supported consumer boundary.
- Crash or corruption around a pointer/view: reconstruct owner lifetime and mutation invalidation first; do not silence an unsafe import name with a cast.
- Termination across a call: find an escaping C++ exception and contain it in a `noexcept` C++ entry point.
- Deadlock during callback replacement or teardown: check whether a captured Swift value is released while a seam lock is held.
- Unexpected copies or slow traversal: check C++ value semantics and container bridging; avoid C++ iterators in Swift and measure before choosing conversion or borrowing.

## Maintain the reference

The vendored guide is intentionally unmodified. See [references/upstream.md](references/upstream.md) for its exact source revision, digests, and license. Check the vendored guide and license against the latest canonical upstream content with `collider skill verify swift-cxx-interop`. Refresh all Collider-managed reference files with `collider skill sync swift-cxx-interop` when verification reports drift. Do not edit the vendored guide, provenance, license, or generated topic index by hand.
