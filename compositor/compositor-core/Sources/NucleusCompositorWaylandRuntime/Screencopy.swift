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

/// Immutable geometry advertised for one frame and reused for its eventual
/// copy. `sourceRegion` is in output pixels; nil means the full output.
struct ScreencopyConfiguration {
    let params: ScreencopyParams
    let sourceRegion: WlRect?
}

/// Result of filling a client buffer with the capture.
struct ScreencopyResult: Sendable {
    var ok: Bool
    var tvSecHi: UInt32
    var tvSecLo: UInt32
    var tvNsec: UInt32
    var flags: UInt32  // zwlr_screencopy_frame_v1.flags (y_invert = 1)
}

/// The render seam. params advertises the buffer for an output/region (nil =
/// uncapturable → failed); capture fills the client buffer and reports timing/flags.
@MainActor
protocol ScreencopyDelegate: AnyObject {
    func screencopyConfiguration(
        output: WlOutput?, region: WlRect?
    ) -> ScreencopyConfiguration?
    func screencopyRequestFrame(output: WlOutput?)
    func screencopyCapture(
        output: WlOutput?, configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>, withDamage: Bool,
        preferRegionReadback: Bool,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64?
    func screencopyCancelCapture(_ requestID: UInt64)
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

@MainActor
private final class WeakScreencopyFrame {
    weak var frame: ScreencopyFrame?

    init(_ frame: ScreencopyFrame) {
        self.frame = frame
    }
}

@MainActor
final class ScreencopyManager {
    weak var delegate: ScreencopyDelegate?
    private var pendingFrames: [UInt64: [WeakScreencopyFrame]] = [:]
    private var admittedByClient: [UInt: Int] = [:]
    private var admittedByOutput: [UInt64: Int] = [:]
    private var admittedTotal = 0
    private static let maximumCapturesPerClient = 8
    private static let maximumCapturesPerOutput = 8
    private static let maximumCapturesGlobal = 32

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwlr_screencopy_manager_v1(), version: 3,
            impl: self, bind: Self.bind)
    }

    fileprivate func configuration(
        output: WlOutput?, region: WlRect?
    ) -> ScreencopyConfiguration? {
        delegate?.screencopyConfiguration(
            output: output, region: region)
    }
    fileprivate func capture(
        output: WlOutput?, configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>, withDamage: Bool,
        preferRegionReadback: Bool,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64? {
        delegate?.screencopyCapture(
            output: output, configuration: configuration,
            overlayCursor: overlayCursor,
            buffer: buffer, withDamage: withDamage,
            preferRegionReadback: preferRegionReadback,
            completion: completion)
    }

    fileprivate func enqueue(_ frame: ScreencopyFrame, output: WlOutput) {
        let outputID = output.outputId
        guard outputID != 0 else {
            frame.failQueuedCopy()
            return
        }
        guard admit(clientKey: frame.clientKey, outputID: outputID) else {
            frame.failQueuedCopy()
            return
        }
        frame.holdAdmission(outputID: outputID)
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
        let liveFrames = frames.compactMap(\.frame)
        let preferRegionReadback = liveFrames.count == 1
        for frame in liveFrames {
            frame.completeQueuedCopy(
                preferRegionReadback: preferRegionReadback)
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

    private func admit(clientKey: UInt, outputID: UInt64) -> Bool {
        guard admittedTotal < Self.maximumCapturesGlobal,
              admittedByClient[clientKey, default: 0]
                < Self.maximumCapturesPerClient,
              admittedByOutput[outputID, default: 0]
                < Self.maximumCapturesPerOutput
        else { return false }
        admittedTotal += 1
        admittedByClient[clientKey, default: 0] += 1
        admittedByOutput[outputID, default: 0] += 1
        return true
    }

    fileprivate func releaseAdmission(
        clientKey: UInt, outputID: UInt64
    ) {
        guard admittedTotal > 0 else { return }
        admittedTotal -= 1
        if let count = admittedByClient[clientKey] {
            admittedByClient[clientKey] = count > 1 ? count - 1 : nil
        }
        if let count = admittedByOutput[outputID] {
            admittedByOutput[outputID] = count > 1 ? count - 1 : nil
        }
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let data else { return }
        let clientBits = UInt(bitPattern: client)
        let dataBits = UInt(bitPattern: data)
        MainActor.assumeIsolated {
            guard let client = OpaquePointer(bitPattern: clientBits),
                  let data = UnsafeMutableRawPointer(bitPattern: dataBits),
                  let me = NucleusWaylandRouter.impl(
                    data, as: ScreencopyManager.self)
            else { return }
            _ = WaylandResource.create(
                client: client,
                interface: swift_wayland_iface_zwlr_screencopy_manager_v1(),
                version: Int32(version),
                id: id,
                vtable: ZwlrScreencopyManagerV1Server.vtable,
                owner: me)
        }
    }

    private func makeFrame(
        frame frameId: WlNewId, output: UnsafeMutablePointer<wl_resource>?,
        region: WlRect?, overlayCursor: Bool
    ) {
        let version = frameId.version
        let outputObj = WlOutput.from(output)
        let frame = ScreencopyFrame(
            manager: self, output: outputObj,
            clientKey: UInt(bitPattern: frameId.client),
            overlayCursor: overlayCursor, version: version)
        guard let fres = frameId.create(vtable: ZwlrScreencopyFrameV1Server.vtable, owner: frame)
        else { return }
        frame.bind(fres)
        guard let configuration = configuration(
            output: outputObj, region: region)
        else {
            zwlr_screencopy_frame_v1_send_failed(fres)
            return
        }
        frame.configuration = configuration
        let p = configuration.params
        zwlr_screencopy_frame_v1_send_buffer(fres, p.shmFormat, p.width, p.height, p.stride)
        if version >= 3 {
            zwlr_screencopy_frame_v1_send_linux_dmabuf(fres, p.drmFourcc, p.width, p.height)
            zwlr_screencopy_frame_v1_send_buffer_done(fres)
        }
    }
}

extension ScreencopyManager: ZwlrScreencopyManagerV1Requests {
    // capture_output(frame, overlay_cursor, output)
    nonisolated func captureOutput(
        _ resource: UnsafeMutablePointer<wl_resource>,
        frame: WlNewId,
        overlay_cursor: Int32,
        output: UnsafeMutablePointer<wl_resource>?
    ) {
        let clientBits = UInt(bitPattern: frame.client)
        let frameID = frame.id
        let frameVersion = frame.version
        let interfaceBits = frame.interface.map { UInt(bitPattern: $0) }
        let outputBits = output.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated {
            guard let client = OpaquePointer(bitPattern: clientBits) else {
                return
            }
            let frame = WlNewId(
                client: client,
                id: frameID,
                version: frameVersion,
                interface: interfaceBits.flatMap {
                    UnsafePointer<wl_interface>(bitPattern: $0)
                })
            makeFrame(
                frame: frame,
                output: outputBits.flatMap {
                    UnsafeMutablePointer<wl_resource>(bitPattern: $0)
                },
                region: nil,
                overlayCursor: overlay_cursor != 0)
        }
    }

    // capture_output_region(frame, overlay_cursor, output, x, y, width, height)
    nonisolated func captureOutputRegion(
        _ resource: UnsafeMutablePointer<wl_resource>,
        frame: WlNewId,
        overlay_cursor: Int32,
        output: UnsafeMutablePointer<wl_resource>?,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        let clientBits = UInt(bitPattern: frame.client)
        let frameID = frame.id
        let frameVersion = frame.version
        let interfaceBits = frame.interface.map { UInt(bitPattern: $0) }
        let outputBits = output.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated {
            guard let client = OpaquePointer(bitPattern: clientBits) else {
                return
            }
            let frame = WlNewId(
                client: client,
                id: frameID,
                version: frameVersion,
                interface: interfaceBits.flatMap {
                    UnsafePointer<wl_interface>(bitPattern: $0)
                })
            makeFrame(
                frame: frame,
                output: outputBits.flatMap {
                    UnsafeMutablePointer<wl_resource>(bitPattern: $0)
                },
                region: WlRect(
                    x: x, y: y, width: width, height: height),
                overlayCursor: overlay_cursor != 0)
        }
    }
}

/// zwlr_screencopy_frame_v1 owner (Rule 9). One copy per frame.
@MainActor
final class ScreencopyFrame {
    private final class CaptureCallState {
        var hasReturned = false
        var inlineResult: ScreencopyResult?
    }

    private weak var manager: ScreencopyManager?
    private weak var output: WlOutput?
    fileprivate let clientKey: UInt
    private let overlayCursor: Bool
    private let version: Int32
    private var resource: UnsafeMutablePointer<wl_resource>?
    fileprivate var configuration: ScreencopyConfiguration?
    private var used = false
    private var pendingBuffer: WaylandResourceReference?
    private var pendingWithDamage = false
    private var pendingCaptureID: UInt64?
    private var admittedOutputID: UInt64?

    init(
        manager: ScreencopyManager, output: WlOutput?, clientKey: UInt,
        overlayCursor: Bool, version: Int32
    ) {
        self.manager = manager
        self.output = output
        self.clientKey = clientKey
        self.overlayCursor = overlayCursor
        self.version = version
        // A live frame means a client is mid-capture: force composition (block direct
        // scanout) until it is done and the frame is destroyed.
        ScreencopyActivity.retainFrame()
    }
    isolated deinit {
        if let pendingCaptureID {
            manager?.delegate?.screencopyCancelCapture(pendingCaptureID)
        }
        releaseAdmission()
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
        guard let configuration else {
            zwlr_screencopy_frame_v1_send_failed(res)
            return
        }
        if !bufferMatchesParams(buffer, configuration.params) {
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

    fileprivate func holdAdmission(outputID: UInt64) {
        precondition(admittedOutputID == nil)
        admittedOutputID = outputID
    }

    private func releaseAdmission() {
        guard let outputID = admittedOutputID else { return }
        admittedOutputID = nil
        manager?.releaseAdmission(
            clientKey: clientKey, outputID: outputID)
    }

    fileprivate func completeQueuedCopy(
        preferRegionReadback: Bool
    ) {
        guard resource != nil,
            let buffer = pendingBuffer?.resource,
            let configuration
        else {
            releaseAdmission()
            pendingBuffer = nil
            return
        }
        let withDamage = pendingWithDamage
        let callState = CaptureCallState()
        let requestID = manager?.capture(
            output: output, configuration: configuration,
            overlayCursor: overlayCursor,
            buffer: buffer,
            withDamage: withDamage,
            preferRegionReadback: preferRegionReadback,
            completion: { [weak self] result in
                guard callState.hasReturned else {
                    callState.inlineResult = result
                    return
                }
                self?.finishQueuedCopy(
                    result: result,
                    withDamage: withDamage)
            })
        callState.hasReturned = true
        if let inlineResult = callState.inlineResult {
            finishQueuedCopy(
                result: inlineResult,
                withDamage: withDamage)
            return
        }
        guard let requestID else {
            failQueuedCopy()
            return
        }
        pendingCaptureID = requestID
    }

    private func finishQueuedCopy(
        result: ScreencopyResult,
        withDamage: Bool
    ) {
        pendingCaptureID = nil
        releaseAdmission()
        guard let res = resource, pendingBuffer?.resource != nil else {
            pendingBuffer = nil
            return
        }
        pendingBuffer = nil
        guard result.ok else {
            zwlr_screencopy_frame_v1_send_failed(res)
            return
        }
        zwlr_screencopy_frame_v1_send_flags(res, result.flags)
        if withDamage, let p = configuration?.params {
            // We do not retain cross-frame damage history, so report the whole
            // destination buffer in buffer-local coordinates.
            zwlr_screencopy_frame_v1_send_damage(
                res, 0, 0, p.width, p.height)
        }
        zwlr_screencopy_frame_v1_send_ready(res, result.tvSecHi, result.tvSecLo, result.tvNsec)
    }

    fileprivate func failQueuedCopy() {
        if let pendingCaptureID {
            manager?.delegate?.screencopyCancelCapture(pendingCaptureID)
            self.pendingCaptureID = nil
        }
        releaseAdmission()
        pendingBuffer = nil
        guard let resource else { return }
        zwlr_screencopy_frame_v1_send_failed(resource)
    }
}

extension ScreencopyFrame: ZwlrScreencopyFrameV1Requests {
    nonisolated func copy(
        _ resource: UnsafeMutablePointer<wl_resource>,
        buffer: UnsafeMutablePointer<wl_resource>?
    ) {
        performCopyFromProtocol(
            resourceBits: UInt(bitPattern: resource),
            bufferBits: buffer.map { UInt(bitPattern: $0) },
            withDamage: false)
    }
    nonisolated func copyWithDamage(
        _ resource: UnsafeMutablePointer<wl_resource>,
        buffer: UnsafeMutablePointer<wl_resource>?
    ) {
        performCopyFromProtocol(
            resourceBits: UInt(bitPattern: resource),
            bufferBits: buffer.map { UInt(bitPattern: $0) },
            withDamage: true)
    }

    nonisolated private func performCopyFromProtocol(
        resourceBits: UInt,
        bufferBits: UInt?,
        withDamage: Bool
    ) {
        MainActor.assumeIsolated {
            guard let resource = UnsafeMutablePointer<wl_resource>(
                bitPattern: resourceBits)
            else { return }
            performCopy(
                res: resource,
                buffer: bufferBits.flatMap {
                    UnsafeMutablePointer<wl_resource>(bitPattern: $0)
                },
                withDamage: withDamage)
        }
    }
}
