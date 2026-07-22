import NucleusRenderer
import NucleusCompositorSignalC
import Glibc
import Synchronization

/// Thread-safe eventfd wake owned by the compositor reactor.
package final class CompositorRenderWakeSink: AsyncRenderWakeSink {
    package struct Metrics: Sendable, Equatable {
        package var wakeRequests: UInt64
        package var signalsWritten: UInt64
        package var signalFailures: UInt64
        package var signalsDroppedAfterClose: UInt64
        package var isClosed: Bool
    }

    private struct State: Sendable {
        var fileDescriptor: Int32
        var wakeRequests: UInt64 = 0
        var signalsWritten: UInt64 = 0
        var signalFailures: UInt64 = 0
        var signalsDroppedAfterClose: UInt64 = 0
    }

    private let state: Mutex<State>

    package var fileDescriptor: Int32 {
        state.withLock { $0.fileDescriptor }
    }

    package init?() {
        let fd = nucleus_compositor_create_render_wake_fd()
        guard fd >= 0 else { return nil }
        state = Mutex(State(fileDescriptor: fd))
    }

    deinit {
        shutdown()
    }

    package nonisolated func signalRenderWork() {
        state.withLock { state in
            state.wakeRequests &+= 1
            guard state.fileDescriptor >= 0 else {
                state.signalsDroppedAfterClose &+= 1
                return
            }
            // Keep the lock through the syscall. Otherwise shutdown can close
            // and recycle this descriptor before the write reaches the kernel.
            if nucleus_compositor_signal_render_wake(
                state.fileDescriptor) != 0 {
                state.signalsWritten &+= 1
            } else {
                state.signalFailures &+= 1
            }
        }
    }

    package func drain() -> Bool {
        state.withLock { state in
            guard state.fileDescriptor >= 0 else { return false }
            return nucleus_compositor_consume_render_wake(
                state.fileDescriptor) > 0
        }
    }

    package nonisolated func shutdown() {
        state.withLock { state in
            guard state.fileDescriptor >= 0 else { return }
            close(state.fileDescriptor)
            state.fileDescriptor = -1
        }
    }

    package nonisolated var metrics: Metrics {
        state.withLock { state in
            Metrics(
                wakeRequests: state.wakeRequests,
                signalsWritten: state.signalsWritten,
                signalFailures: state.signalFailures,
                signalsDroppedAfterClose: state.signalsDroppedAfterClose,
                isClosed: state.fileDescriptor < 0)
        }
    }
}
