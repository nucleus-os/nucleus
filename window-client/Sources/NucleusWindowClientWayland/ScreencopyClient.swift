// The wlr-screencopy client — the consumer side (thumbnails, screenshots). Skeleton for the
// bar vertical slice: the shape (bind the manager, request a frame for an output, receive the
// buffer format, attach a wl_shm buffer, copy, read `ready`/`failed`) is complete; the
// wl_shm buffer allocation + pixel readback is the fleshing-out step when a screenshot/overview
// panel lands. The compositor is the screencopy PRODUCER; this is its client counterpart.

public import WaylandClientDispatch
import WaylandProtocolTypes

@MainActor
@safe public final class NucleusDesktopScreencopyClient {
    private let manager:
        WaylandProxy<ZwlrScreencopyManagerV1Client>
    private weak var client: NucleusDesktopConnection?

    public init?(client: NucleusDesktopConnection) {
        guard let manager = client.screencopy else { return nil }
        self.manager = manager
        self.client = client
    }

    /// A single capture request for one output. The completion receives the raw pixels once
    /// the compositor signals `ready`. Skeleton: `capture` binds the frame + listener; the
    /// buffer/format negotiation + wl_shm copy is the additive step.
    @MainActor
    @safe public final class Capture {
        let frame: WaylandProxy<ZwlrScreencopyFrameV1Client>
        var onReady: ((_ width: UInt32, _ height: UInt32) -> Void)?
        init(frame: WaylandProxy<ZwlrScreencopyFrameV1Client>) {
            self.frame = frame
        }

        isolated deinit {
            // The generated listener borrows this object. Destroy the owned
            // proxy before ARC releases the callback target.
            try? frame.destroy()
        }
    }

    /// Request a capture of `output` (optionally including the cursor).
    public func capture(output: NucleusDesktopOutput, includeCursor: Bool,
                        onReady: @escaping (UInt32, UInt32) -> Void) -> Capture? {
        guard let frame = try? manager.captureOutput(
            overlay_cursor: includeCursor ? 1 : 0,
            output: output.proxy)
        else {
            return nil
        }
        let capture = Capture(frame: frame)
        capture.onReady = onReady
        do {
            try frame.installListener(capture)
        } catch {
            try? frame.destroy()
            return nil
        }
        return capture
    }
}

extension NucleusDesktopScreencopyClient.Capture: ZwlrScreencopyFrameV1Events {
    public func buffer(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, format: WlShmFormat, width: UInt32, height: UInt32, stride: UInt32) {
        // Allocate a wl_shm buffer of this size, then zwlr_screencopy_frame_v1_copy(proxy, buffer). (additive)
    }
    public func flags(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, flags: ZwlrScreencopyFrameV1Flags) {}
    public func ready(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, tv_sec_hi: UInt32, tv_sec_lo: UInt32, tv_nsec: UInt32) {
        onReady?(0, 0)
    }
    public func failed(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>) {}
    public func damage(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, x: UInt32, y: UInt32, width: UInt32, height: UInt32) {}
    public func linuxDmabuf(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>, format: UInt32, width: UInt32, height: UInt32) {}
    public func bufferDone(_ proxy: WaylandBorrowedProxy<ZwlrScreencopyFrameV1Client>) {}
}
