import NucleusRenderer
import NucleusShellSignalC
import Glibc
import Synchronization

/// Thread-safe eventfd wake owned by the shell event loop.
package final class ShellRenderWakeSink: AsyncRenderWakeSink {
    private struct State: Sendable {
        var fileDescriptor: Int32
    }

    private let state: Mutex<State>

    package var fileDescriptor: Int32 {
        state.withLock { $0.fileDescriptor }
    }

    package init?() {
        let fd = nucleus_shell_create_render_wake_fd()
        guard fd >= 0 else { return nil }
        state = Mutex(State(fileDescriptor: fd))
    }

    deinit {
        shutdown()
    }

    package nonisolated func signalRenderWork() {
        state.withLock { state in
            guard state.fileDescriptor >= 0 else { return }
            // Serialize the syscall with close so a late producer cannot write
            // through a recycled descriptor number.
            _ = nucleus_shell_signal_render_wake(state.fileDescriptor)
        }
    }

    package func drain() -> Bool {
        state.withLock { state in
            guard state.fileDescriptor >= 0 else { return false }
            return nucleus_shell_consume_render_wake(state.fileDescriptor) > 0
        }
    }

    package nonisolated func shutdown() {
        state.withLock { state in
            guard state.fileDescriptor >= 0 else { return }
            close(state.fileDescriptor)
            state.fileDescriptor = -1
        }
    }
}
