import Glibc

struct XwaylandLaunchConfiguration: Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String]

    init(executablePath: String, displayNumber: UInt8) {
        self.executablePath = executablePath
        arguments = [
            executablePath,
            "-rootless",
            "-terminate",
            "-force-xrandr-emulation",
            "-listenfd", "6",
            "-listenfd", "7",
            "-wm", "4",
            "-displayfd", "5",
            ":\(displayNumber)",
        ]
        environment = ["WAYLAND_SOCKET=3"]
    }

    var executableIsValid: Bool {
        guard executablePath.hasPrefix("/"),
              unsafe access(executablePath, X_OK) == 0
        else {
            return false
        }
        var metadata = stat()
        return unsafe lstat(executablePath, &metadata) == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}
