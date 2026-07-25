// The wlr-screencopy client — the consumer side (thumbnails, screenshots). Skeleton for the
// bar vertical slice: the shape (bind the manager, request a frame for an output, receive the
// buffer format, attach a wl_shm buffer, copy, read `ready`/`failed`) is complete; the
// wl_shm buffer allocation + pixel readback is the fleshing-out step when a screenshot/overview
// panel lands. The compositor is the screencopy PRODUCER; this is its client counterpart.

import WaylandClientC
public import WaylandClientDispatch
import WaylandProtocolTypes

@MainActor
@safe public final class ScreencopyClient {
    private let manager: OpaquePointer
    private weak var client: ShellWaylandClient?

    public init?(client: ShellWaylandClient) {
        guard let manager = unsafe client.proxy(.screencopy) else { return nil }
        unsafe self.manager = manager
        self.client = client
    }

    /// A single capture request for one output. The completion receives the raw pixels once
    /// the compositor signals `ready`. Skeleton: `capture` binds the frame + listener; the
    /// buffer/format negotiation + wl_shm copy is the additive step.
    @safe public final class Capture {
        let frame: OpaquePointer
        var onReady: ((_ width: UInt32, _ height: UInt32) -> Void)?
        init(frame: OpaquePointer) { unsafe self.frame = frame }

        deinit {
            // The generated listener borrows this object. Destroy the owned
            // proxy before ARC releases the callback target.
            unsafe zwlr_screencopy_frame_v1_destroy(frame)
        }
    }

    /// Request a capture of `output` (optionally including the cursor).
    public func capture(output: WaylandOutput, includeCursor: Bool,
                        onReady: @escaping (UInt32, UInt32) -> Void) -> Capture? {
        guard let frame = unsafe zwlr_screencopy_manager_v1_capture_output(
            manager, includeCursor ? 1 : 0, output.proxy) else { return nil }
        let capture = unsafe Capture(frame: frame)
        capture.onReady = onReady
        unsafe ZwlrScreencopyFrameV1Client.addListener(frame, owner: capture)
        return capture
    }
}

// The generated event dispatch is nonisolated (a @convention(c) libwayland callback). The owner is
// the per-capture object (not @MainActor), so its own scratch state is reached directly.
extension ScreencopyClient.Capture: ZwlrScreencopyFrameV1Events {
    public nonisolated func buffer(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, format: WlShmFormat, width: UInt32, height: UInt32, stride: UInt32) {
        // Allocate a wl_shm buffer of this size, then zwlr_screencopy_frame_v1_copy(proxy, buffer). (additive)
    }
    public nonisolated func flags(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, flags: ZwlrScreencopyFrameV1Flags) {}
    public nonisolated func ready(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, tv_sec_hi: UInt32, tv_sec_lo: UInt32, tv_nsec: UInt32) {
        // Capture is a plain (non-@MainActor) per-capture owner, so onReady is nonisolated state
        // reached directly — no actor hop, and nothing non-Sendable crosses a boundary.
        onReady?(0, 0)  // dimensions filled from the buffer event once wired
    }
    public nonisolated func failed(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>) {}
    public nonisolated func damage(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, x: UInt32, y: UInt32, width: UInt32, height: UInt32) {}
    public nonisolated func linuxDmabuf(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, format: UInt32, width: UInt32, height: UInt32) {}
    public nonisolated func bufferDone(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>) {}
}
