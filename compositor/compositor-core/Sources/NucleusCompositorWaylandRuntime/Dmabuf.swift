// zwp_linux_dmabuf_v1 on the router. Lets a client wrap a set of dmabuf planes
// (one fd per plane, shared from the GPU) into a wl_buffer the compositor can
// scan out or sample directly. The router owns the params accumulation, the
// structural validation + protocol errors, the created/failed handshake, and the
// v4+ feedback (format table + tranches); the render side (delegate) supplies the
// importable format/modifier set, the main device, and the actual import.
//
// Advanced to the protocol's v5. The
// delivered plane fds are owned by the server: held by the buffer once imported,
// closed by the params/buffer owner otherwise.

import Glibc
import NucleusLinuxPrimitives
import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

/// One advertised format + DRM modifier the compositor can import.
struct DmabufFormat: Equatable {
    var format: UInt32
    var modifier: UInt64
}

/// One dmabuf plane plus its shared, single-close fd owner.
struct DmabufPlane {
    let fdOwner: LinuxSharedFileDescriptor
    var offset: UInt32
    var stride: UInt32

    init(consumingFd fd: Int32, offset: UInt32, stride: UInt32) {
        fdOwner = LinuxSharedFileDescriptor(adopting: fd)
        self.offset = offset
        self.stride = stride
    }

    borrowing func withBorrowedDescriptor<Result: ~Copyable, Failure: Error>(
        _ body: (borrowing LinuxBorrowedFileDescriptor) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try fdOwner.withBorrowedDescriptor(body)
    }
}

/// A fully-specified dmabuf the render side is asked to import.
struct DmabufAttrs {
    var width: Int32
    var height: Int32
    var format: UInt32
    var modifier: UInt64
    var planes: [DmabufPlane]
}

struct DmabufProbePlane: Sendable {
    let fd: Int32
    let offset: UInt32
    let stride: UInt32
}

struct DmabufProbeSnapshot: Sendable {
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let modifier: UInt64
    let planes: [DmabufProbePlane]

    init?(_ attrs: DmabufAttrs) {
        guard attrs.width > 0, attrs.height > 0, !attrs.planes.isEmpty else {
            return nil
        }
        width = UInt32(attrs.width)
        height = UInt32(attrs.height)
        format = attrs.format
        modifier = attrs.modifier
        planes = attrs.planes.map { plane in
            plane.withBorrowedDescriptor {
                DmabufProbePlane(
                    fd: $0.rawValue,
                    offset: plane.offset,
                    stride: plane.stride)
            }
        }
    }
}

/// The render seam. The router asks the delegate which formats/modifiers it can
/// import, the GPU main device, and to import a fully-specified dmabuf.
@MainActor
protocol DmabufDelegate: AnyObject {
    func dmabufSupportedFormats() -> [DmabufFormat]
    func dmabufMainDevice() -> UInt64
    func dmabufImport(_ attrs: DmabufAttrs) -> Bool
}

@MainActor
@safe final class ZwpLinuxDmabuf {
    weak var delegate: (any DmabufDelegate)?

    func supportedFormats() -> [DmabufFormat] { delegate?.dmabufSupportedFormats() ?? [] }
    fileprivate func mainDevice() -> UInt64 { delegate?.dmabufMainDevice() ?? 0 }
    fileprivate func importDmabuf(_ attrs: DmabufAttrs) -> Bool {
        delegate?.dmabufImport(attrs) ?? false
    }

    /// Create a feedback object and emit one atomic update: a format table memfd, a
    /// main device, and one tranche covering all formats. The feedback resource has
    /// no per-object state, so it owns the manager (`self`) like other resources.
    /// Feedback is destroy-only and uses generated dispatch.
    fileprivate func makeFeedback(
        _ id: WlNewId<ZwpLinuxDmabufFeedbackV1Server>
    ) {
        _ = id.create(
            owner: { handle in
                DmabufFeedback(resource: handle)
            },
            installed: { feedback in
                self.sendFeedback(feedback.resource)
            })
    }

    private func sendFeedback(
        _ resource:
            WaylandResourceHandle<ZwpLinuxDmabufFeedbackV1Server>
    ) {
        let formats = supportedFormats()
        guard formats.count <= Int(UInt16.max) else {
            resource.postNoMemory()
            return
        }

        // format_table: packed { u32 format, u32 pad, u64 modifier } per entry.
        var table: [UInt8] = []
        for f in formats {
            appendLE32(&table, f.format)
            appendLE32(&table, 0)
            appendLE64(&table, f.modifier)
        }
        guard
            let tableFile = try? LinuxSealedFile(
                name: "nucleus-dmabuf-table",
                bytes: table)
        else {
            resource.postNoMemory()
            return
        }
        let tableSize = UInt32(tableFile.size)
        tableFile.withBorrowedDescriptor {
            _ = resource.sendFormatTable(
                fd: $0.rawValue,
                size: tableSize)
        }

        var device = dev_t(mainDevice())
        let deviceBytes = withUnsafeBytes(of: &device) { unsafe Array($0) }
        resource.sendMainDevice(device: deviceBytes)
        resource.sendTrancheTargetDevice(device: deviceBytes)

        var indices: [UInt8] = []
        for i in 0..<formats.count { appendLE16(&indices, UInt16(i)) }
        resource.sendTrancheFormats(indices: indices)
        resource.sendTrancheFlags(flags: [])
        resource.sendTrancheDone()
        resource.sendDone()
    }
}

extension ZwpLinuxDmabuf: ZwpLinuxDmabufV1Requests {
    func createParams(
        _ request: WaylandRequest<ZwpLinuxDmabufV1Server>,
        params_id: WlNewId<ZwpLinuxBufferParamsV1Server>
    ) {
        _ = params_id.create { handle in
            ZwpLinuxBufferParams(resource: handle, manager: self)
        }
    }

    func getDefaultFeedback(
        _ request: WaylandRequest<ZwpLinuxDmabufV1Server>,
        id: WlNewId<ZwpLinuxDmabufFeedbackV1Server>
    ) {
        makeFeedback(id)
    }

    func getSurfaceFeedback(
        _ request: WaylandRequest<ZwpLinuxDmabufV1Server>,
        id: WlNewId<ZwpLinuxDmabufFeedbackV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        makeFeedback(id)
    }
}

/// zwp_linux_buffer_params_v1 owner (Rule 9): accumulates planes, validates, and
/// produces a wl_buffer or a failure.
@MainActor
@safe final class ZwpLinuxBufferParams {
    private let resource: WaylandResourceHandle<ZwpLinuxBufferParamsV1Server>
    private weak var manager: ZwpLinuxDmabuf?
    private var planes: [Int: DmabufPlane] = [:]
    private var modifier: UInt64?
    private var used = false

    init(
        resource: WaylandResourceHandle<ZwpLinuxBufferParamsV1Server>,
        manager: ZwpLinuxDmabuf
    ) {
        self.resource = resource
        self.manager = manager
    }

    /// Validate the accumulated planes and assemble the attrs, or post the protocol
    /// error. Returns nil on error (the params is left used).
    private func assemble(
        width: Int32,
        height: Int32,
        format: UInt32,
        flags: UInt32
    ) -> DmabufAttrs? {
        guard !used else {
            resource.postError(.alreadyUsed, message: "params already used")
            return nil
        }
        used = true
        let layouts: [DmabufPlaneLayout]
        do {
            layouts = try DmabufLayoutValidator.validate(
                width: width, height: height, flags: flags,
                indexedPlanes: planes.mapValues {
                    DmabufPlaneLayout(offset: $0.offset, stride: $0.stride)
                })
        } catch {
            let protocolError: ZwpLinuxBufferParamsV1Error
            let message: String
            switch error {
            case .incompletePlanes:
                protocolError = .incomplete
                message = "incomplete or gapped planes"
            case .invalidDimensions:
                protocolError = .invalidDimensions
                message = "non-positive dimensions"
            case .unsupportedFlags:
                protocolError = .invalidFormat
                message = "unsupported linux-dmabuf flags"
            case .invalidPlaneCount:
                protocolError = .invalidFormat
                message = "format requires exactly one plane"
            case .zeroStride:
                protocolError = .outOfBounds
                message = "zero plane stride"
            case .undersizedStride:
                protocolError = .outOfBounds
                message = "plane stride is undersized"
            case .layoutOverflow:
                protocolError = .outOfBounds
                message = "plane layout overflows"
            case .mixedModifiers:
                protocolError = .invalidFormat
                message = "all planes must use the same modifier"
            }
            resource.postError(protocolError, message: message)
            return nil
        }
        let ordered = layouts.indices.map { planes[$0]! }
        let modifier = self.modifier ?? 0
        let supported =
            manager?.supportedFormats().contains(
                DmabufFormat(format: format, modifier: modifier)) ?? false
        guard supported else {
            resource.postError(
                .invalidFormat,
                message: "format/modifier not supported")
            return nil
        }
        return DmabufAttrs(
            width: width, height: height, format: format, modifier: modifier, planes: ordered)
    }
}

extension ZwpLinuxBufferParams: ZwpLinuxBufferParamsV1Requests {
    // add(fd, plane_idx, offset, stride, modifier_hi, modifier_lo)
    func add(
        _ request: WaylandRequest<ZwpLinuxBufferParamsV1Server>,
        fd: consuming WaylandOwnedFileDescriptor, plane_idx planeIdx: UInt32,
        offset: UInt32, stride: UInt32, modifier_hi modHi: UInt32, modifier_lo modLo: UInt32
    ) {
        guard planeIdx < 4 else {
            request.postError(.planeIdx, message: "plane index out of range")
            return
        }
        guard planes[Int(planeIdx)] == nil else {
            request.postError(.planeSet, message: "plane already set")
            return
        }
        let incomingModifier = (UInt64(modHi) << 32) | UInt64(modLo)
        do {
            try DmabufLayoutValidator.validateModifier(
                current: modifier, incoming: incomingModifier)
        } catch {
            request.postError(
                .invalidFormat,
                message: "all planes must use the same modifier")
            return
        }
        modifier = incomingModifier
        planes[Int(planeIdx)] = DmabufPlane(
            consumingFd: fd.take(), offset: offset, stride: stride)
    }

    // create(width, height, format, flags): async — created or failed.
    func create(
        _ request: WaylandRequest<ZwpLinuxBufferParamsV1Server>, width: Int32, height: Int32,
        format: UInt32, flags: ZwpLinuxBufferParamsV1Flags
    ) {
        guard let manager = manager else { return }
        guard
            let attrs = assemble(
                width: width, height: height, format: format,
                flags: flags.rawValue)
        else {
            return  // protocol error already posted
        }
        planes = [:]  // fds transferred into the buffer
        guard manager.importDmabuf(attrs) else {
            self.resource.sendFailed()
            return
        }
        _ = resource.createCreated(
            owner: { handle in
                DmabufBuffer(resource: handle, attrs: attrs)
            })
    }

    // create_immed(buffer_id, width, height, format, flags): synchronous.
    func createImmed(
        _ request: WaylandRequest<ZwpLinuxBufferParamsV1Server>,
        buffer_id bufferId: WlNewId<WlBufferServer>,
        width: Int32, height: Int32, format: UInt32, flags: ZwpLinuxBufferParamsV1Flags
    ) {
        guard let manager = manager else { return }
        guard
            let attrs = assemble(
                width: width, height: height, format: format,
                flags: flags.rawValue)
        else {
            return
        }
        planes = [:]
        guard manager.importDmabuf(attrs) else {
            request.postError(
                .invalidWlBuffer,
                message: "dmabuf import failed")
            return
        }
        _ = bufferId.create { handle in
            DmabufBuffer(resource: handle, attrs: attrs)
        }
    }
}

/// A dmabuf-backed wl_buffer (Rule 9). Owns its plane fds; closes them when the
/// client destroys the buffer. The live surface importer reads its validated attrs.
final class DmabufBuffer {
    let resource: WaylandResourceHandle<WlBufferServer>
    let attrs: DmabufAttrs
    init(resource: WaylandResourceHandle<WlBufferServer>, attrs: DmabufAttrs) {
        self.resource = resource
        self.attrs = attrs
    }

}

@MainActor
private final class DmabufFeedback {
    let resource: WaylandResourceHandle<ZwpLinuxDmabufFeedbackV1Server>

    init(
        resource: WaylandResourceHandle<ZwpLinuxDmabufFeedbackV1Server>
    ) {
        self.resource = resource
    }
}

// MARK: - little-endian + wl_array helpers

private func appendLE16(_ out: inout [UInt8], _ v: UInt16) {
    out.append(UInt8(v & 0xff))
    out.append(UInt8((v >> 8) & 0xff))
}
private func appendLE32(_ out: inout [UInt8], _ v: UInt32) {
    for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
}
private func appendLE64(_ out: inout [UInt8], _ v: UInt64) {
    for i in 0..<8 { out.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
}
