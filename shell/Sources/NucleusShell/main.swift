import NucleusShellRuntime
#if canImport(Glibc)
import Glibc
#endif

// The native Nucleus shell. WAYLAND_DISPLAY (or the default socket) selects
// the compositor; all product UI is retained Swift authored with NucleusUI.

@MainActor
func main() async -> Int32 {
    let socket = getenv("WAYLAND_DISPLAY").map { String(cString: $0) }

    guard let host = ShellHost(socketName: socket) else {
        FileHandle_stderr("nucleus-shell: could not connect to the compositor "
            + "(WAYLAND_DISPLAY=\(socket ?? "<default>")) or bring up the render device\n")
        return 1
    }
    await host.run()
    return 0
}

private func FileHandle_stderr(_ s: String) {
    _ = s.withCString { write(2, $0, strlen($0)) }
}

exit(await main())
