import NucleusShellRuntime
import NucleusTextBackend
#if canImport(Glibc)
import Glibc
#endif

// The Nucleus shell executable. Connects to the compositor named by WAYLAND_DISPLAY, mounts
// the shell's RN bar as a layer-shell surface, and drives it until the compositor disconnects
// or a signal requests exit.
//
// The bundle path comes from NUCLEUS_SHELL_BUNDLE (a file path to the bar .hbc), else the
// installed default. WAYLAND_DISPLAY (else the default socket) selects the compositor.

@MainActor
func main() -> Int32 {
    SkiaTextLayoutBackend.installIfNeeded()
    let bundlePath: String = {
        if let env = getenv("NUCLEUS_SHELL_BUNDLE") { return String(cString: env) }
        return "/usr/share/nucleus-shell/bundles/bar.hbc"
    }()
    let bundleURL = bundlePath.hasPrefix("file://") ? bundlePath : "file://" + bundlePath

    let socket = getenv("WAYLAND_DISPLAY").map { String(cString: $0) }

    guard let host = ShellHost(bundleURL: bundleURL, socketName: socket) else {
        FileHandle_stderr("nucleus-shell: could not connect to the compositor "
            + "(WAYLAND_DISPLAY=\(socket ?? "<default>")) or bring up the render device\n")
        return 1
    }
    host.run()
    return 0
}

private func FileHandle_stderr(_ s: String) {
    _ = s.withCString { write(2, $0, strlen($0)) }
}

exit(main())
