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
import WaylandProtocolTypes
import NucleusRenderModel

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
        buffer: WaylandResourceReference<WlBufferServer>,
        withDamage: Bool,
        preferRegionReadback: Bool,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64?
    func screencopyCancelCapture(_ requestID: UInt64)
}
/// Live screencopy-frame activity (M2 direct-scanout prerequisite). A capture reads
/// the composited output, so while any client holds a screencopy frame (from the
/// capture request until it destroys the frame) the affected outputs must composite
/// rather than direct-scanout, or the copy would read a stale/absent framebuffer. The
/// eligibility gather reads `isCapturing`. Frames, their isolated deinits, and
/// scanout-fact gathering are all main-actor-owned, so the counter shares that
/// semantic owner instead of introducing cross-thread mutable state.
@MainActor
enum ScreencopyActivity {
    private static var liveFrames = 0
    static var isCapturing: Bool { liveFrames > 0 }
    static func retainFrame() { liveFrames += 1 }
    static func releaseFrame() {
        precondition(liveFrames > 0, "unbalanced screencopy frame lifetime")
        liveFrames -= 1
    }
}

@MainActor
final class ScreencopyManager {
    weak var delegate: (any ScreencopyDelegate)?
    private var pendingFrames:
        [UInt64: WeakObjectList<ScreencopyFrame>] = [:]
    private var admittedByClient: [WaylandClientID: Int] = [:]
    private var admittedByOutput: [UInt64: Int] = [:]
    private var admittedTotal = 0
    private static let maximumCapturesPerClient = 8
    private static let maximumCapturesPerOutput = 8
    private static let maximumCapturesGlobal = 32

    fileprivate func configuration(
        output: WlOutput?, region: WlRect?
    ) -> ScreencopyConfiguration? {
        delegate?.screencopyConfiguration(
            output: output, region: region)
    }
    fileprivate func capture(
        output: WlOutput?, configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        buffer: WaylandResourceReference<WlBufferServer>,
        withDamage: Bool,
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
        pendingFrames[outputID, default: WeakObjectList()].append(frame)
        delegate?.screencopyRequestFrame(output: output)
    }

    /// Complete captures only after the renderer accepted a new submission for
    /// their output. At this point the composited accumulator contains the exact
    /// frame requested by `copy`, rather than an older frame that happened to be
    /// resident while the Wayland request was dispatched.
    func outputSubmitted(_ outputID: UInt64) {
        var frames = pendingFrames.removeValue(forKey: outputID)
            ?? WeakObjectList()
        let liveFrames = frames.liveValues()
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
        var frames = pendingFrames.removeValue(forKey: outputID)
            ?? WeakObjectList()
        for frame in frames.liveValues() {
            frame.failQueuedCopy()
        }
    }

    private func admit(clientKey: WaylandClientID, outputID: UInt64) -> Bool {
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
        clientKey: WaylandClientID, outputID: UInt64
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

    private func makeFrame(
        frame frameId: WlNewId<ZwlrScreencopyFrameV1Server>,
        output outputObj: WlOutput?,
        region: WlRect?, overlayCursor: Bool
    ) {
        let version = frameId.version
        let clientID = frameId.clientID
        _ = frameId.create(
            owner: { handle in
                ScreencopyFrame(
                    resource: handle,
                    manager: self,
                    output: outputObj,
                    clientKey: clientID,
                    overlayCursor: overlayCursor,
                    version: version)
            },
            installed: { frame in
                frame.installed()
                guard let configuration = self.configuration(
                    output: outputObj, region: region)
                else {
                    frame.resource.sendFailed()
                    return
                }
                frame.configuration = configuration
                let p = configuration.params
                frame.resource.sendBuffer(
                    format: WlShmFormat(rawValue: p.shmFormat),
                    width: p.width, height: p.height, stride: p.stride)
                if frame.resource.supportsLinuxDmabuf {
                    frame.resource.sendLinuxDmabuf(
                        format: p.drmFourcc,
                        width: p.width, height: p.height)
                    frame.resource.sendBufferDone()
                }
            })
    }
}

extension ScreencopyManager: ZwlrScreencopyManagerV1Requests {
    // capture_output(frame, overlay_cursor, output)
    func captureOutput(
        _ request: WaylandRequest<ZwlrScreencopyManagerV1Server>,
        frame: WlNewId<ZwlrScreencopyFrameV1Server>,
        overlay_cursor: Int32,
        output: WaylandBorrowedObject<WlOutputServer>
    ) {
        makeFrame(
            frame: frame,
            output: output.output,
            region: nil,
            overlayCursor: overlay_cursor != 0)
    }

    // capture_output_region(frame, overlay_cursor, output, x, y, width, height)
    func captureOutputRegion(
        _ request: WaylandRequest<ZwlrScreencopyManagerV1Server>,
        frame: WlNewId<ZwlrScreencopyFrameV1Server>,
        overlay_cursor: Int32,
        output: WaylandBorrowedObject<WlOutputServer>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        makeFrame(
            frame: frame,
            output: output.output,
            region: WlRect(
                x: x, y: y, width: width, height: height),
            overlayCursor: overlay_cursor != 0)
    }
}

/// zwlr_screencopy_frame_v1 owner (Rule 9). One copy per frame.
@MainActor
@safe final class ScreencopyFrame {
    private final class CaptureCallState {
        var hasReturned = false
        var inlineResult: ScreencopyResult?
    }

    private weak var manager: ScreencopyManager?
    private weak var output: WlOutput?
    fileprivate let clientKey: WaylandClientID
    private let overlayCursor: Bool
    private let version: Int32
    fileprivate let resource:
        WaylandResourceHandle<ZwlrScreencopyFrameV1Server>
    fileprivate var configuration: ScreencopyConfiguration?
    private var used = false
    private var pendingBuffer:
        WaylandResourceReference<WlBufferServer>?
    private var pendingWithDamage = false
    private var pendingCaptureID: UInt64?
    private var captureGeneration: UInt64 = 0
    private var activeCaptureGeneration: UInt64?
    private var admittedOutputID: UInt64?

    init(
        resource: WaylandResourceHandle<ZwlrScreencopyFrameV1Server>,
        manager: ScreencopyManager, output: WlOutput?, clientKey: WaylandClientID,
        overlayCursor: Bool, version: Int32
    ) {
        self.resource = resource
        self.manager = manager
        self.output = output
        self.clientKey = clientKey
        self.overlayCursor = overlayCursor
        self.version = version
    }

    fileprivate func installed() {
        ScreencopyActivity.retainFrame()
    }
    isolated deinit {
        if let pendingCaptureID {
            manager?.delegate?.screencopyCancelCapture(pendingCaptureID)
        }
        releaseAdmission()
        ScreencopyActivity.releaseFrame()
    }
    /// Whether the client's attached wl_buffer matches the advertised capture params.
    /// shm buffers are validated by format/width/height/stride; dmabuf buffers by
    /// fourcc/width/height. An unrecognized buffer type fails validation (→ invalid_buffer).
    private func bufferMatchesParams(
        _ buffer: WaylandResourceReference<WlBufferServer>,
        _ p: ScreencopyParams
    ) -> Bool {
        if let shm = buffer.shmMetadata {
            return shm.format == p.shmFormat
                && UInt32(shm.width) == p.width
                && UInt32(shm.height) == p.height
                && UInt32(shm.stride) == p.stride
        }
        if let dmabuf = buffer.retainedSemanticOwner(
            as: DmabufBuffer.self)
        {
            return dmabuf.attrs.format == p.drmFourcc
                && UInt32(bitPattern: dmabuf.attrs.width) == p.width
                && UInt32(bitPattern: dmabuf.attrs.height) == p.height
        }
        return false
    }

    private func performCopy(
        buffer: WaylandBorrowedObject<WlBufferServer>?,
        withDamage: Bool
    ) {
        guard !used else {
            resource.postError(.alreadyUsed, message: "frame already used")
            return
        }
        guard let buffer else {
            resource.postError(.invalidBuffer, message: "invalid buffer")
            return
        }
        // Validate the attached buffer against the advertised params before capture:
        // a format/size/stride mismatch is invalid_buffer (value 1), and rejecting it
        // here prevents an out-of-bounds readback into an undersized client buffer.
        guard let configuration else {
            resource.sendFailed()
            return
        }
        let semanticOwner = buffer.owner(as: DmabufBuffer.self)
        guard let bufferReference = buffer.retainedReference(
            retaining: semanticOwner)
        else {
            resource.sendFailed()
            return
        }
        if !bufferMatchesParams(
            bufferReference,
            configuration.params)
        {
            resource.postError(
                .invalidBuffer,
                message: "buffer does not match advertised format/size")
            return
        }
        used = true
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
        guard resource.isLive,
            let buffer = pendingBuffer,
            let configuration
        else {
            releaseAdmission()
            pendingBuffer = nil
            return
        }
        let withDamage = pendingWithDamage
        captureGeneration &+= 1
        precondition(
            captureGeneration != 0,
            "screencopy capture generation exhausted")
        let generation = captureGeneration
        activeCaptureGeneration = generation
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
                    withDamage: withDamage,
                    generation: generation)
            })
        callState.hasReturned = true
        if let inlineResult = callState.inlineResult {
            finishQueuedCopy(
                result: inlineResult,
                withDamage: withDamage,
                generation: generation)
            return
        }
        guard let requestID else {
            failQueuedCopy()
            return
        }
        guard activeCaptureGeneration == generation else { return }
        pendingCaptureID = requestID
    }

    private func finishQueuedCopy(
        result: ScreencopyResult,
        withDamage: Bool,
        generation: UInt64
    ) {
        guard activeCaptureGeneration == generation else { return }
        activeCaptureGeneration = nil
        pendingCaptureID = nil
        releaseAdmission()
        guard resource.isLive,
            pendingBuffer?.isLive == true
        else {
            pendingBuffer = nil
            return
        }
        pendingBuffer = nil
        guard result.ok else {
            resource.sendFailed()
            return
        }
        resource.sendFlags(
            flags: ZwlrScreencopyFrameV1Flags(rawValue: result.flags))
        if withDamage, let p = configuration?.params {
            // We do not retain cross-frame damage history, so report the whole
            // destination buffer in buffer-local coordinates.
            resource.sendDamage(
                x: 0, y: 0, width: p.width, height: p.height)
        }
        resource.sendReady(
            tv_sec_hi: result.tvSecHi,
            tv_sec_lo: result.tvSecLo,
            tv_nsec: result.tvNsec)
    }

    fileprivate func failQueuedCopy() {
        activeCaptureGeneration = nil
        if let pendingCaptureID {
            manager?.delegate?.screencopyCancelCapture(pendingCaptureID)
            self.pendingCaptureID = nil
        }
        releaseAdmission()
        pendingBuffer = nil
        resource.sendFailed()
    }
}

extension ScreencopyFrame: ZwlrScreencopyFrameV1Requests {
    func copy(
        _ request: WaylandRequest<ZwlrScreencopyFrameV1Server>,
        buffer: WaylandBorrowedObject<WlBufferServer>
    ) {
        performCopy(buffer: buffer, withDamage: false)
    }
    func copyWithDamage(
        _ request: WaylandRequest<ZwlrScreencopyFrameV1Server>,
        buffer: WaylandBorrowedObject<WlBufferServer>
    ) {
        performCopy(buffer: buffer, withDamage: true)
    }
}
