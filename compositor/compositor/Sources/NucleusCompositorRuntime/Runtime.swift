import NucleusCompositorRuntimeEntry

// Process control of the compositor lives in Swift from here. The executable
// entry (`main.swift`) hands off to `nucleus_runtime_main`, which does session
// isolation itself; on return the entry maps the result to a process exit code.
//
// Swift owns the full lifecycle: `CompositorRuntime` discovers the DRM device,
// brings the compositor up, runs the io_uring loop (a Swift-owned
// `SystemPackage.IORing`), and tears it down. The compositor is single-threaded
// on the process's main thread, which is the `@MainActor` executor; this entry establishes that
// isolation once.
@c @implementation
func nucleus_runtime_main() -> Int32 {
    // Session-runtime isolation first: validate the launcher-provided runtime dir
    // or create + export the direct-run fallback, so XDG_RUNTIME_DIR is set before
    // the router adds its listen socket. Torn down after the loop returns.
    let session: SessionIsolation
    do {
        session = try SessionIsolation.start(.fromEnvironment())
    } catch {
        logRuntime("session isolation failed: \(error)")
        return Int32(1)
    }
    defer { session.shutdown() }

    return MainActor.assumeIsolated {
        guard let runtime = CompositorRuntime() else { return Int32(1) }
        guard runtime.bringUp() else {
            runtime.teardown()
            return Int32(1)
        }
        runtime.run()
        runtime.teardown()
        return Int32(0)
    }
}
