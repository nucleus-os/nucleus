/*
 * NucleusRuntimeEntry — the compositor process-control inversion boundary.
 *
 * `nucleus_runtime_main` is implemented in Swift (the NucleusCompositorRuntime
 * module, via `@c @implementation`) and called by the Swift process entry
 * (`NucleusCompositor/main.swift`). It is the point where process control of the
 * compositor crosses the module boundary into the runtime. Swift owns the whole
 * lifecycle from here: it discovers the DRM device, brings the compositor up,
 * runs the io_uring loop, and tears it down.
 *
 * The event loop is a Swift-owned io_uring (SystemPackage.IORing) created inside
 * the runtime. Returns a process exit code (0 = ok).
 */
#ifndef NUCLEUS_RUNTIME_ENTRY_H
#define NUCLEUS_RUNTIME_ENTRY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Implemented in Swift (NucleusCompositorRuntime); called by main.swift. */
int32_t nucleus_runtime_main(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NUCLEUS_RUNTIME_ENTRY_H */
