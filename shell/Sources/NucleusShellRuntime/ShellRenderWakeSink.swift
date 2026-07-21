import NucleusRenderer
import NucleusShellSignalC
import Glibc

/// Thread-safe eventfd wake owned by the shell event loop.
final class ShellRenderWakeSink: AsyncRenderWakeSink {
    let fileDescriptor: Int32

    init?() {
        let fd = nucleus_shell_create_render_wake_fd()
        guard fd >= 0 else { return nil }
        fileDescriptor = fd
    }

    deinit {
        close(fileDescriptor)
    }

    nonisolated func signalRenderWork() {
        _ = nucleus_shell_signal_render_wake(fileDescriptor)
    }

    func drain() -> Bool {
        nucleus_shell_consume_render_wake(fileDescriptor) > 0
    }
}
