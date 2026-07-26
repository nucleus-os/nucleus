import NucleusShellRuntime
import NucleusDiagnostics
import NucleusSessionProtocol
#if canImport(Glibc)
import Glibc
#endif

// The native Nucleus shell. WAYLAND_DISPLAY (or the default socket) selects
// the compositor; all product UI is retained Swift authored with NucleusUI.

@MainActor
func main() async -> Int32 {
    let socket: String?
    if let value = unsafe getenv("WAYLAND_DISPLAY") {
        socket = unsafe String(cString: value)
    } else {
        socket = nil
    }

    let configuration: SessionConfiguration
    let readiness: SessionReadinessReporter?
    do {
        configuration = try SessionConfiguration.inherited()
        readiness = try SessionReadinessReporter.inherited(role: .shell)
    } catch {
        NucleusLogger(subsystem: "shell").error(
            "invalid session readiness channel: \(error)")
        return 1
    }

    guard let host = ShellHost(
        socketName: socket,
        configuration: configuration)
    else {
        NucleusLogger(subsystem: "shell").error(
            "could not connect to the compositor "
                + "(WAYLAND_DISPLAY=\(socket ?? "<default>")) or bring up the render device")
        return 1
    }
    await host.run(readinessReporter: readiness)
    return 0
}

exit(await main())
