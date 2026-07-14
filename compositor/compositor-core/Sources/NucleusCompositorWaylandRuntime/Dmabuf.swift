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
import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// One advertised format + DRM modifier the compositor can import.
struct DmabufFormat: Equatable {
    var format: UInt32
    var modifier: UInt64
}

/// One dmabuf plane: an fd (server-owned) plus its layout.
struct DmabufPlane {
    var fd: Int32
    var offset: UInt32
    var stride: UInt32
}

/// A fully-specified dmabuf the render side is asked to import.
struct DmabufAttrs {
    var width: Int32
    var height: Int32
    var format: UInt32
    var modifier: UInt64
    var planes: [DmabufPlane]
}

/// The render seam. The router asks the delegate which formats/modifiers it can
/// import, the GPU main device, and to import a fully-specified dmabuf.
protocol DmabufDelegate: AnyObject {
    func dmabufSupportedFormats() -> [DmabufFormat]
    func dmabufMainDevice() -> UInt64
    func dmabufImport(_ attrs: DmabufAttrs) -> Bool
}
extension DmabufDelegate {
    func dmabufSupportedFormats() -> [DmabufFormat] { [] }
    func dmabufMainDevice() -> UInt64 { 0 }
    func dmabufImport(_ attrs: DmabufAttrs) -> Bool { true }
}

final class ZwpLinuxDmabuf {
    weak var delegate: DmabufDelegate?

    // wl_buffer and zwp_linux_dmabuf_feedback_v1 are destroy-only (no generated
    // dispatch): their request vtables stay hand-wired. wl_buffer's is passed to
    // id.create when create_immed materializes a buffer; the feedback's is used in
    // makeFeedback.
    private let feedbackVtable: UnsafeMutableRawPointer
    let bufferVtable: UnsafeMutableRawPointer

    init() {
        feedbackVtable = allocVtable(
            MemoryLayout<swift_wayland_zwp_linux_dmabuf_feedback_v1_requests>.stride,
            MemoryLayout<swift_wayland_zwp_linux_dmabuf_feedback_v1_requests>.alignment)
        let fvt = feedbackVtable.bindMemory(
            to: swift_wayland_zwp_linux_dmabuf_feedback_v1_requests.self, capacity: 1)
        fvt.pointee.destroy = Self.feedbackDestroy

        bufferVtable = allocVtable(
            MemoryLayout<swift_wayland_wl_buffer_requests>.stride,
            MemoryLayout<swift_wayland_wl_buffer_requests>.alignment)
        let bvt = bufferVtable.bindMemory(to: swift_wayland_wl_buffer_requests.self, capacity: 1)
        bvt.pointee.destroy = DmabufBuffer.objectDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwp_linux_dmabuf_v1(), version: 5, impl: self, bind: Self.bind)
    }

    fileprivate func supportedFormats() -> [DmabufFormat] { delegate?.dmabufSupportedFormats() ?? [] }
    fileprivate func mainDevice() -> UInt64 { delegate?.dmabufMainDevice() ?? 0 }
    fileprivate func importDmabuf(_ attrs: DmabufAttrs) -> Bool {
        delegate?.dmabufImport(attrs) ?? true
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: ZwpLinuxDmabuf.self) else {
            return
        }
        guard let res = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwp_linux_dmabuf_v1(),
            version: Int32(version), id: id, vtable: ZwpLinuxDmabufV1Server.vtable, owner: me)
        else { return }
        // v<4 advertises formats/modifiers on bind; v>=4 uses feedback objects.
        if version < 4 {
            for f in me.supportedFormats() {
                if version >= 3 {
                    zwp_linux_dmabuf_v1_send_modifier(
                        res, f.format, UInt32(f.modifier >> 32), UInt32(f.modifier & 0xffff_ffff))
                } else {
                    zwp_linux_dmabuf_v1_send_format(res, f.format)
                }
            }
        }
    }

    private static let feedbackDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    /// Create a feedback object and emit one atomic update: a format table memfd, a
    /// main device, and one tranche covering all formats. The feedback resource has
    /// no per-object state, so it owns the manager (`self`) like other resources.
    /// Feedback is destroy-only: materialize with its hand-wired request vtable.
    fileprivate func makeFeedback(_ id: WlNewId) {
        guard let res = id.create(vtable: UnsafeRawPointer(feedbackVtable), owner: self)
        else { return }
        let formats = supportedFormats()

        // format_table: packed { u32 format, u32 pad, u64 modifier } per entry.
        var table: [UInt8] = []
        for f in formats {
            appendLE32(&table, f.format)
            appendLE32(&table, 0)
            appendLE64(&table, f.modifier)
        }
        let fd = memfd_create("nucleus-dmabuf-table", 0)
        if fd >= 0 {
            if !table.isEmpty {
                _ = ftruncate(fd, off_t(table.count))
                _ = table.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
            zwp_linux_dmabuf_feedback_v1_send_format_table(res, fd, UInt32(table.count))
            close(fd)
        }

        var deviceBytes: [UInt8] = []
        appendLE64(&deviceBytes, mainDevice())
        withWlArray(deviceBytes) { zwp_linux_dmabuf_feedback_v1_send_main_device(res, $0) }
        withWlArray(deviceBytes) { zwp_linux_dmabuf_feedback_v1_send_tranche_target_device(res, $0) }

        var indices: [UInt8] = []
        for i in 0..<formats.count { appendLE16(&indices, UInt16(i)) }
        withWlArray(indices) { zwp_linux_dmabuf_feedback_v1_send_tranche_formats(res, $0) }
        zwp_linux_dmabuf_feedback_v1_send_tranche_flags(res, 0)
        zwp_linux_dmabuf_feedback_v1_send_tranche_done(res)
        zwp_linux_dmabuf_feedback_v1_send_done(res)
    }

    deinit {
        feedbackVtable.deallocate()
        bufferVtable.deallocate()
    }
}

extension ZwpLinuxDmabuf: ZwpLinuxDmabufV1Requests {
    func createParams(_ resource: UnsafeMutablePointer<wl_resource>, params_id: WlNewId) {
        let params = ZwpLinuxBufferParams(manager: self)
        _ = params_id.create(vtable: ZwpLinuxBufferParamsV1Server.vtable, owner: params)
    }

    func getDefaultFeedback(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        makeFeedback(id)
    }

    func getSurfaceFeedback(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        surface: UnsafeMutablePointer<wl_resource>?
    ) {
        makeFeedback(id)
    }
}

/// zwp_linux_buffer_params_v1 owner (Rule 9): accumulates planes, validates, and
/// produces a wl_buffer or a failure.
final class ZwpLinuxBufferParams {
    private weak var manager: ZwpLinuxDmabuf?
    private var planes: [Int: DmabufPlane] = [:]
    private var modifier: UInt64 = 0
    private var used = false

    init(manager: ZwpLinuxDmabuf) { self.manager = manager }

    /// Validate the accumulated planes and assemble the attrs, or post the protocol
    /// error. Returns nil on error (the params is left used).
    private func assemble(width: Int32, height: Int32, format: UInt32, res: UnsafeMutablePointer<wl_resource>) -> DmabufAttrs? {
        guard !used else {
            swift_wayland_resource_post_error(res, 0, "params already used")  // already_used
            return nil
        }
        used = true
        let count = planes.count
        guard count > 0, (0..<count).allSatisfy({ planes[$0] != nil }) else {
            swift_wayland_resource_post_error(res, 3, "incomplete or gapped planes")  // incomplete
            return nil
        }
        guard width > 0, height > 0 else {
            swift_wayland_resource_post_error(res, 5, "non-positive dimensions")  // invalid_dimensions
            return nil
        }
        let supported = manager?.supportedFormats().contains(
            DmabufFormat(format: format, modifier: modifier)) ?? false
        guard supported else {
            swift_wayland_resource_post_error(res, 4, "format/modifier not supported")  // invalid_format
            return nil
        }
        let ordered = (0..<count).map { planes[$0]! }
        return DmabufAttrs(
            width: width, height: height, format: format, modifier: modifier, planes: ordered)
    }

    deinit { for p in planes.values where p.fd >= 0 { close(p.fd) } }
}

extension ZwpLinuxBufferParams: ZwpLinuxBufferParamsV1Requests {
    // add(fd, plane_idx, offset, stride, modifier_hi, modifier_lo)
    func add(
        _ resource: UnsafeMutablePointer<wl_resource>, fd: Int32, plane_idx planeIdx: UInt32,
        offset: UInt32, stride: UInt32, modifier_hi modHi: UInt32, modifier_lo modLo: UInt32
    ) {
        guard planeIdx < 4 else {
            swift_wayland_resource_post_error(resource, 1, "plane index out of range")  // plane_idx
            if fd >= 0 { close(fd) }
            return
        }
        guard planes[Int(planeIdx)] == nil else {
            swift_wayland_resource_post_error(resource, 2, "plane already set")  // plane_set
            if fd >= 0 { close(fd) }
            return
        }
        modifier = (UInt64(modHi) << 32) | UInt64(modLo)
        planes[Int(planeIdx)] = DmabufPlane(fd: fd, offset: offset, stride: stride)
    }

    // create(width, height, format, flags): async — created or failed.
    func create(
        _ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32,
        format: UInt32, flags: UInt32
    ) {
        guard let client = wl_resource_get_client(resource), let manager = manager else { return }
        guard let attrs = assemble(width: width, height: height, format: format, res: resource) else {
            return  // protocol error already posted
        }
        planes = [:]  // fds transferred into the buffer
        guard manager.importDmabuf(attrs) else {
            for p in attrs.planes where p.fd >= 0 { close(p.fd) }
            zwp_linux_buffer_params_v1_send_failed(resource)
            return
        }
        let buffer = DmabufBuffer(attrs: attrs)
        // The wl_buffer here is a `created` event argument (server-allocated id 0),
        // not a request new_id, so it is created directly with its hand-wired vtable.
        guard let bufRes = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_buffer(), version: 1, id: 0,
            vtable: UnsafeRawPointer(manager.bufferVtable), owner: buffer) else {
            return
        }
        zwp_linux_buffer_params_v1_send_created(resource, bufRes)
    }

    // create_immed(buffer_id, width, height, format, flags): synchronous.
    func createImmed(
        _ resource: UnsafeMutablePointer<wl_resource>, buffer_id bufferId: WlNewId,
        width: Int32, height: Int32, format: UInt32, flags: UInt32
    ) {
        guard let manager = manager else { return }
        guard let attrs = assemble(width: width, height: height, format: format, res: resource) else {
            return
        }
        planes = [:]
        let imported = manager.importDmabuf(attrs)
        let buffer = DmabufBuffer(attrs: attrs)
        // wl_buffer is destroy-only: materialize with its hand-wired request vtable.
        guard bufferId.create(vtable: UnsafeRawPointer(manager.bufferVtable), owner: buffer) != nil
        else { return }
        if !imported {
            swift_wayland_resource_post_error(resource, 7, "dmabuf import failed")  // invalid_wl_buffer
        }
    }
}

/// A dmabuf-backed wl_buffer (Rule 9). Owns its plane fds; closes them when the
/// client destroys the buffer. The scene reads its attrs at #12.
final class DmabufBuffer {
    let attrs: DmabufAttrs
    init(attrs: DmabufAttrs) { self.attrs = attrs }

    fileprivate static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    deinit { for p in attrs.planes where p.fd >= 0 { close(p.fd) } }
}

// MARK: - little-endian + wl_array helpers

private func appendLE16(_ out: inout [UInt8], _ v: UInt16) {
    out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff))
}
private func appendLE32(_ out: inout [UInt8], _ v: UInt32) {
    for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
}
private func appendLE64(_ out: inout [UInt8], _ v: UInt64) {
    for i in 0..<8 { out.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
}

/// Build a transient wl_array over `bytes` for an array-typed event send. The send
/// copies the bytes into the wire, so the array need only live across the call.
private func withWlArray(_ bytes: [UInt8], _ body: (UnsafeMutablePointer<wl_array>) -> Void) {
    var bytes = bytes
    bytes.withUnsafeMutableBytes { raw in
        var arr = wl_array()
        arr.size = raw.count
        arr.alloc = raw.count
        arr.data = raw.baseAddress
        withUnsafeMutablePointer(to: &arr) { body($0) }
    }
}
