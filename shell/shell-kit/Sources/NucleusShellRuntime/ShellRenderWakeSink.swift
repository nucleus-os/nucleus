import Dispatch
import Glibc
package import NucleusAppHostProtocols
import NucleusShellSignalC
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

package func runShellThreadSanitizerHarness() {
    let producerCount = 8
    let requestsPerProducer = 2_048
    var exercisedDescriptorReuse = false

    for _ in 0..<64 {
        guard let sink = ShellRenderWakeSink() else {
            fatalError("failed to create shell render wake sink")
        }
        let originalDescriptor = sink.fileDescriptor
        let group = DispatchGroup()
        for _ in 0..<producerCount {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<requestsPerProducer {
                    sink.signalRenderWork()
                }
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().async {
            sink.shutdown()
            group.leave()
        }
        group.wait()
        sink.shutdown()

        let replacement = nucleus_shell_create_render_wake_fd()
        precondition(replacement >= 0)
        exercisedDescriptorReuse =
            exercisedDescriptorReuse
            || replacement == originalDescriptor
        for _ in 0..<256 { sink.signalRenderWork() }
        precondition(
            nucleus_shell_consume_render_wake(replacement) == 0,
            "a late shell render wake targeted a recycled descriptor")
        close(replacement)
    }

    precondition(
        exercisedDescriptorReuse,
        "shell render-wake stress did not exercise descriptor-number reuse")
}
