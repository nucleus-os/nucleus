import NucleusRenderer
import NucleusCompositorSignalC
import Glibc

/// Thread-safe eventfd wake owned by the compositor reactor.
final class CompositorRenderWakeSink: AsyncRenderWakeSink {
    let fileDescriptor: Int32

    init?() {
        let fd = nucleus_compositor_create_render_wake_fd()
        guard fd >= 0 else { return nil }
        fileDescriptor = fd
    }

    deinit {
        close(fileDescriptor)
    }

    nonisolated func signalRenderWork() {
        _ = nucleus_compositor_signal_render_wake(fileDescriptor)
    }

    func drain() -> Bool {
        nucleus_compositor_consume_render_wake(fileDescriptor) > 0
    }
}
