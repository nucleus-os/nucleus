// zwlr_screencopy_manager_v1 on the router. Lets a privileged client capture an
// output (or a region of it) into a wl_buffer it provides — screenshots, screen
// recording, remote desktop. The router owns the frame handshake (advertise the
// required buffer, accept a copy, report flags + timing or failure); the render
// side (delegate) supplies the capture geometry/format and performs the copy.
//
// Capture advertises the buffer params,
// the client allocates a matching wl_buffer and calls copy/copy_with_damage, and
// the compositor fills it and reports ready (or failed).

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import Synchronization

/// Buffer the client must allocate to receive a capture.
struct ScreencopyParams {
    var shmFormat: UInt32   // wl_shm.format
    var width: UInt32
    var height: UInt32
    var stride: UInt32
    var drmFourcc: UInt32   // for the linux_dmabuf advertisement (v3+)
}

/// Result of filling a client buffer with the capture.
struct ScreencopyResult {
    var ok: Bool
    var tvSecHi: UInt32
    var tvSecLo: UInt32
    var tvNsec: UInt32
    var flags: UInt32  // zwlr_screencopy_frame_v1.flags (y_invert = 1)
}

/// The render seam. params advertises the buffer for an output/region (nil =
/// uncapturable → failed); capture fills the client buffer and reports timing/flags.
protocol ScreencopyDelegate: AnyObject {
    func screencopyParams(output: WlOutput?, region: WlRect?) -> ScreencopyParams?
    func screencopyRequestFrame(output: WlOutput?)
    func screencopyCapture(
        output: WlOutput?, region: WlRect?, overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>, withDamage: Bool) -> ScreencopyResult
}
/// Live screencopy-frame activity (M2 direct-scanout prerequisite). A capture reads
/// the composited output, so while any client holds a screencopy frame (from the
/// capture request until it destroys the frame) the affected outputs must composite
/// rather than direct-scanout, or the copy would read a stale/absent framebuffer. The
/// eligibility gather reads `isCapturing`. Resource teardown can run from deinit,
/// so the counter owns its synchronization instead of asserting an executor there.
enum ScreencopyActivity {
    private static let liveFrames = Mutex(0)
    static var isCapturing: Bool { liveFrames.withLock { $0 > 0 } }
    static func retainFrame() { liveFrames.withLock { $0 += 1 } }
    static func releaseFrame() {
        liveFrames.withLock {
            precondition($0 > 0, "unbalanced screencopy frame lifetime")
            $0 -= 1
        }
    }
}

private final class WeakScreencopyFrame {
    weak var frame: ScreencopyFrame?

    init(_ frame: ScreencopyFrame) {
        self.frame = frame
    }
}

final class ScreencopyManager {
    weak var delegate: ScreencopyDelegate?
    private var pendingFrames: [UInt64: [WeakScreencopyFrame]] = [:]

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwlr_screencopy_manager_v1(), version: 3,
            impl: self, bind: Self.bind)
    }

    fileprivate func params(output: WlOutput?, region: WlRect?) -> ScreencopyParams? {
        delegate?.screencopyParams(output: output, region: region)
    }
    fileprivate func capture(
        output: WlOutput?, region: WlRect?, overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>, withDamage: Bool) -> ScreencopyResult {
        delegate?.screencopyCapture(
            output: output, region: region, overlayCursor: overlayCursor,
            buffer: buffer, withDamage: withDamage)
            ?? ScreencopyResult(ok: false, tvSecHi: 0, tvSecLo: 0, tvNsec: 0, flags: 0)
    }

    fileprivate func enqueue(_ frame: ScreencopyFrame, output: WlOutput) {
        let outputID = output.outputId
        guard outputID != 0 else {
            frame.failQueuedCopy()
            return
        }
        var frames = pendingFrames[outputID, default: []]
        frames.removeAll { $0.frame == nil }
        frames.append(WeakScreencopyFrame(frame))
        pendingFrames[outputID] = frames
        delegate?.screencopyRequestFrame(output: output)
    }

    /// Complete captures only after the renderer accepted a new submission for
    /// their output. At this point the composited accumulator contains the exact
    /// frame requested by `copy`, rather than an older frame that happened to be
    /// resident while the Wayland request was dispatched.
    func outputSubmitted(_ outputID: UInt64) {
        let frames = pendingFrames.removeValue(forKey: outputID) ?? []
        for frame in frames.compactMap(\.frame) {
            frame.completeQueuedCopy()
        }
    }

    /// A removed output can no longer produce the frame promised to its pending
    /// captures. Existing frame resources remain valid and receive one terminal
    /// `failed` event.
    func outputRemoved(_ outputID: UInt64) {
        let frames = pendingFrames.removeValue(forKey: outputID) ?? []
        for frame in frames.compactMap(\.frame) {
            frame.failQueuedCopy()
        }
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: ScreencopyManager.self) else {
            return
        }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwlr_screencopy_manager_v1(),
            version: Int32(version), id: id, vtable: ZwlrScreencopyManagerV1Server.vtable, owner: me)
    }

    private func makeFrame(
        frame frameId: WlNewId, output: UnsafeMutablePointer<wl_resource>?,
        region: WlRect?, overlayCursor: Bool
    ) {
        let version = frameId.version
        let outputObj = WlOutput.from(output)
        let frame = ScreencopyFrame(
            manager: self, output: outputObj, region: region,
            overlayCursor: overlayCursor, version: version)
        guard let fres = frameId.create(vtable: ZwlrScreencopyFrameV1Server.vtable, owner: frame)
        else { return }
        frame.bind(fres)
        guard let p = params(output: outputObj, region: region) else {
            zwlr_screencopy_frame_v1_send_failed(fres)
            return
        }
        frame.params = p
        zwlr_screencopy_frame_v1_send_buffer(fres, p.shmFormat, p.width, p.height, p.stride)
        if version >= 3 {
            zwlr_screencopy_frame_v1_send_linux_dmabuf(fres, p.drmFourcc, p.width, p.height)
            zwlr_screencopy_frame_v1_send_buffer_done(fres)
        }
    }
}

extension ScreencopyManager: ZwlrScreencopyManagerV1Requests {
    // capture_output(frame, overlay_cursor, output)
    func captureOutput(_ resource: UnsafeMutablePointer<wl_resource>, frame: WlNewId,
                       overlay_cursor: Int32, output: UnsafeMutablePointer<wl_resource>?) {
        makeFrame(frame: frame, output: output, region: nil, overlayCursor: overlay_cursor != 0)
    }

    // capture_output_region(frame, overlay_cursor, output, x, y, width, height)
    func captureOutputRegion(_ resource: UnsafeMutablePointer<wl_resource>, frame: WlNewId,
                             overlay_cursor: Int32, output: UnsafeMutablePointer<wl_resource>?,
                             x: Int32, y: Int32, width: Int32, height: Int32) {
        makeFrame(
            frame: frame, output: output,
            region: WlRect(x: x, y: y, width: width, height: height),
            overlayCursor: overlay_cursor != 0)
    }
}

/// zwlr_screencopy_frame_v1 owner (Rule 9). One copy per frame.
final class ScreencopyFrame {
    private weak var manager: ScreencopyManager?
    private weak var output: WlOutput?
    private let region: WlRect?
    private let overlayCursor: Bool
    private let version: Int32
    private var resource: UnsafeMutablePointer<wl_resource>?
    fileprivate var params: ScreencopyParams?
    private var used = false
    private var pendingBuffer: WaylandResourceReference?
    private var pendingWithDamage = false

    init(
        manager: ScreencopyManager, output: WlOutput?, region: WlRect?,
        overlayCursor: Bool, version: Int32
    ) {
        self.manager = manager
        self.output = output
        self.region = region
        self.overlayCursor = overlayCursor
        self.version = version
        // A live frame means a client is mid-capture: force composition (block direct
        // scanout) until it is done and the frame is destroyed.
        ScreencopyActivity.retainFrame()
    }
    deinit {
        ScreencopyActivity.releaseFrame()
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Whether the client's attached wl_buffer matches the advertised capture params.
    /// shm buffers are validated by format/width/height/stride; dmabuf buffers by
    /// fourcc/width/height. An unrecognized buffer type fails validation (→ invalid_buffer).
    private func bufferMatchesParams(_ buffer: UnsafeMutablePointer<wl_resource>, _ p: ScreencopyParams) -> Bool {
        if let shm = wl_shm_buffer_get(buffer) {
            return wl_shm_buffer_get_format(shm) == p.shmFormat
                && UInt32(bitPattern: wl_shm_buffer_get_width(shm)) == p.width
                && UInt32(bitPattern: wl_shm_buffer_get_height(shm)) == p.height
                && UInt32(bitPattern: wl_shm_buffer_get_stride(shm)) == p.stride
        }
        if let dmabuf = WaylandResource.owner(of: buffer, as: DmabufBuffer.self) {
            return dmabuf.attrs.format == p.drmFourcc
                && UInt32(bitPattern: dmabuf.attrs.width) == p.width
                && UInt32(bitPattern: dmabuf.attrs.height) == p.height
        }
        return false
    }

    private func performCopy(
        res: UnsafeMutablePointer<wl_resource>, buffer: UnsafeMutablePointer<wl_resource>?,
        withDamage: Bool
    ) {
        guard !used else {
            swift_wayland_resource_post_error(res, 0, "frame already used")  // already_used
            return
        }
        guard let buffer else {
            swift_wayland_resource_post_error(res, 1, "invalid buffer")  // invalid_buffer
            return
        }
        // Validate the attached buffer against the advertised params before capture:
        // a format/size/stride mismatch is invalid_buffer (value 1), and rejecting it
        // here prevents an out-of-bounds readback into an undersized client buffer.
        if let p = params, !bufferMatchesParams(buffer, p) {
            swift_wayland_resource_post_error(res, 1, "buffer does not match advertised format/size")
            return
        }
        used = true
        // libwayland owns wl_shm buffer user_data; only router-created DMA-BUF
        // resources carry a Swift WaylandResource owner.
        let semanticOwner: DmabufBuffer? =
            wl_shm_buffer_get(buffer) == nil
                ? WaylandResource.owner(
                    of: buffer, as: DmabufBuffer.self)
                : nil
        guard let bufferReference = WaylandResourceReference(
            buffer, retaining: semanticOwner)
        else {
            zwlr_screencopy_frame_v1_send_failed(res)
            return
        }
        pendingBuffer = bufferReference
        pendingWithDamage = withDamage
        guard let manager, let output else {
            failQueuedCopy()
            return
        }
        manager.enqueue(self, output: output)
    }

    fileprivate func completeQueuedCopy() {
        guard let res = resource,
            let buffer = pendingBuffer?.resource
        else {
            pendingBuffer = nil
            return
        }
        let withDamage = pendingWithDamage
        pendingBuffer = nil
        let result = manager?.capture(
            output: output, region: region, overlayCursor: overlayCursor,
            buffer: buffer, withDamage: withDamage)
            ?? ScreencopyResult(
                ok: false, tvSecHi: 0, tvSecLo: 0, tvNsec: 0, flags: 0)
        guard result.ok else {
            zwlr_screencopy_frame_v1_send_failed(res)
            return
        }
        zwlr_screencopy_frame_v1_send_flags(res, result.flags)
        if withDamage, let p = params {
            // Report the whole captured area as damaged.
            let r = region ?? WlRect(x: 0, y: 0, width: Int32(p.width), height: Int32(p.height))
            zwlr_screencopy_frame_v1_send_damage(
                res, UInt32(max(0, r.x)), UInt32(max(0, r.y)),
                UInt32(max(0, r.width)), UInt32(max(0, r.height)))
        }
        zwlr_screencopy_frame_v1_send_ready(res, result.tvSecHi, result.tvSecLo, result.tvNsec)
    }

    fileprivate func failQueuedCopy() {
        pendingBuffer = nil
        guard let resource else { return }
        zwlr_screencopy_frame_v1_send_failed(resource)
    }
}

extension ScreencopyFrame: ZwlrScreencopyFrameV1Requests {
    func copy(_ resource: UnsafeMutablePointer<wl_resource>, buffer: UnsafeMutablePointer<wl_resource>?) {
        performCopy(res: resource, buffer: buffer, withDamage: false)
    }
    func copyWithDamage(_ resource: UnsafeMutablePointer<wl_resource>, buffer: UnsafeMutablePointer<wl_resource>?) {
        performCopy(res: resource, buffer: buffer, withDamage: true)
    }
}
