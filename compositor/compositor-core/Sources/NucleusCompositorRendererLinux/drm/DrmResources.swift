// Phase 10a.2 — Swift noncopyable `drmMode*` result owners + property
// enumeration over real libdrm.
//
// Each KMS describe-the-card result libdrm returns (`drmModeRes`,
// `drmModeConnector`, `drmModeEncoder`, `drmModeCrtc`, `drmModePlane`,
// `drmModePlaneRes`, `drmModeObjectProperties`, `drmModeProperty`,
// `drmModePropertyBlob`) is a heap allocation paired with a `drmModeFree*`.
// These wrappers make that pairing a Swift ownership invariant: one noncopyable
// owner per result, freed exactly once on `deinit`, with the borrowed C arrays
// copied out into value-typed Swift accessors so libdrm memory never escapes
// the owner's lifetime.
//
// On top sits the property enumeration: project an object's properties into
// value-typed entries
// (id + value + name), then resolve a property id/value by name. The name
// matching is pure and value-typed so it is exercised without DRM hardware;
// the libdrm-backed projection runs where a KMS-capable node is open.
//
// Nothing imports it yet.

import NucleusCompositorDrmC

// MARK: - Mode info value

/// A KMS mode, copied out of libdrm's `drmModeModeInfo` so callers never hold a
/// pointer into a `drmModeConnector`'s mode array.
struct DrmModeInfo: Sendable, Equatable {
    var clock: UInt32
    var hdisplay: UInt16
    var vdisplay: UInt16
    var vrefresh: UInt32
    var flags: UInt32
    var type: UInt32
    var name: String

    /// True for the connector's driver-preferred mode (`DRM_MODE_TYPE_PREFERRED`).
    var isPreferred: Bool { (type & UInt32(DRM_MODE_TYPE_PREFERRED)) != 0 }

    init(_ mode: drmModeModeInfo) {
        self.clock = mode.clock
        self.hdisplay = mode.hdisplay
        self.vdisplay = mode.vdisplay
        self.vrefresh = mode.vrefresh
        self.flags = mode.flags
        self.type = mode.type
        var raw = mode.name
        self.name = withUnsafeBytes(of: &raw) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

// MARK: - Resource owners

/// Owns a `drmModeRes` (card resource inventory) and frees it on teardown.
struct DrmResources: ~Copyable {
    private let ptr: drmModeResPtr

    init?(fd: Int32) {
        guard let p = drmModeGetResources(fd) else { return nil }
        self.ptr = p
    }

    var connectorIds: [UInt32] { idArray(ptr.pointee.connectors, ptr.pointee.count_connectors) }
    var crtcIds: [UInt32] { idArray(ptr.pointee.crtcs, ptr.pointee.count_crtcs) }
    var encoderIds: [UInt32] { idArray(ptr.pointee.encoders, ptr.pointee.count_encoders) }
    var fbIds: [UInt32] { idArray(ptr.pointee.fbs, ptr.pointee.count_fbs) }
    var minWidth: UInt32 { ptr.pointee.min_width }
    var maxWidth: UInt32 { ptr.pointee.max_width }
    var minHeight: UInt32 { ptr.pointee.min_height }
    var maxHeight: UInt32 { ptr.pointee.max_height }

    deinit { drmModeFreeResources(ptr) }
}

/// Owns a `drmModeConnector` and frees it on teardown.
struct DrmConnector: ~Copyable {
    private let ptr: drmModeConnectorPtr

    init?(fd: Int32, connectorId: UInt32) {
        guard let p = drmModeGetConnector(fd, connectorId) else { return nil }
        self.ptr = p
    }

    var connectorId: UInt32 { ptr.pointee.connector_id }
    var encoderId: UInt32 { ptr.pointee.encoder_id }
    var connectorType: UInt32 { ptr.pointee.connector_type }
    var connectorTypeId: UInt32 { ptr.pointee.connector_type_id }
    var isConnected: Bool { ptr.pointee.connection == DRM_MODE_CONNECTED }
    var mmWidth: UInt32 { ptr.pointee.mmWidth }
    var mmHeight: UInt32 { ptr.pointee.mmHeight }
    var encoderIds: [UInt32] { idArray(ptr.pointee.encoders, ptr.pointee.count_encoders) }

    var modes: [DrmModeInfo] {
        let count = Int(ptr.pointee.count_modes)
        guard count > 0, let base = ptr.pointee.modes else { return [] }
        return (0..<count).map { DrmModeInfo(base[$0]) }
    }

    /// The driver-preferred mode, else the first mode, else nil.
    var preferredMode: DrmModeInfo? {
        let all = modes
        return all.first(where: { $0.isPreferred }) ?? all.first
    }

    /// Create a KMS MODE_ID property blob at the driver-preferred resolution,
    /// choosing its highest-refresh variant (else the first mode). Some drivers,
    /// including NVIDIA, mark 4K60 preferred even when 4K120 is exposed at the
    /// same resolution. The raw
    /// `drmModeModeInfo` (not the lossy `DrmModeInfo` value copy) is what
    /// `drmModeCreatePropertyBlob` requires. Returns nil when there are no modes
    /// or blob creation fails. The kernel owns the blob until
    /// `drmModeDestroyPropertyBlob`; the DrmOutput teardown releases it.
    func createPreferredModeBlob(fd: Int32) -> (
        blobId: UInt32, width: UInt32, height: UInt32, refreshMhz: Int32
    )? {
        let count = Int(ptr.pointee.count_modes)
        guard count > 0, let base = ptr.pointee.modes else { return nil }
        let preferredIndex = (0..<count).first {
            (base[$0].type & UInt32(DRM_MODE_TYPE_PREFERRED)) != 0
        } ?? 0
        let preferredWidth = base[preferredIndex].hdisplay
        let preferredHeight = base[preferredIndex].vdisplay
        var index = preferredIndex
        for i in 0..<count
        where base[i].hdisplay == preferredWidth && base[i].vdisplay == preferredHeight
            && base[i].vrefresh > base[index].vrefresh {
            index = i
        }
        var blobId: UInt32 = 0
        let rc = drmModeCreatePropertyBlob(
            fd, base.advanced(by: index), MemoryLayout<drmModeModeInfo>.size, &blobId)
        guard rc == 0, blobId != 0 else { return nil }
        return (
            blobId,
            UInt32(base[index].hdisplay),
            UInt32(base[index].vdisplay),
            Int32(base[index].vrefresh) * 1_000
        )
    }

    deinit { drmModeFreeConnector(ptr) }
}

/// Owns a `drmModeEncoder` and frees it on teardown.
struct DrmEncoder: ~Copyable {
    private let ptr: drmModeEncoderPtr

    init?(fd: Int32, encoderId: UInt32) {
        guard let p = drmModeGetEncoder(fd, encoderId) else { return nil }
        self.ptr = p
    }

    var encoderId: UInt32 { ptr.pointee.encoder_id }
    var crtcId: UInt32 { ptr.pointee.crtc_id }
    var possibleCrtcs: UInt32 { ptr.pointee.possible_crtcs }
    var possibleClones: UInt32 { ptr.pointee.possible_clones }

    deinit { drmModeFreeEncoder(ptr) }
}

/// Owns a `drmModeCrtc` and frees it on teardown.
struct DrmCrtc: ~Copyable {
    private let ptr: drmModeCrtcPtr

    init?(fd: Int32, crtcId: UInt32) {
        guard let p = drmModeGetCrtc(fd, crtcId) else { return nil }
        self.ptr = p
    }

    var crtcId: UInt32 { ptr.pointee.crtc_id }
    var bufferId: UInt32 { ptr.pointee.buffer_id }
    var modeValid: Bool { ptr.pointee.mode_valid != 0 }
    var gammaSize: Int32 { ptr.pointee.gamma_size }
    var mode: DrmModeInfo { DrmModeInfo(ptr.pointee.mode) }

    deinit { drmModeFreeCrtc(ptr) }
}

/// Owns a `drmModePlane` and frees it on teardown.
struct DrmPlane: ~Copyable {
    private let ptr: drmModePlanePtr

    init?(fd: Int32, planeId: UInt32) {
        guard let p = drmModeGetPlane(fd, planeId) else { return nil }
        self.ptr = p
    }

    var planeId: UInt32 { ptr.pointee.plane_id }
    var crtcId: UInt32 { ptr.pointee.crtc_id }
    var fbId: UInt32 { ptr.pointee.fb_id }
    var possibleCrtcs: UInt32 { ptr.pointee.possible_crtcs }
    var formats: [UInt32] { idArray(ptr.pointee.formats, ptr.pointee.count_formats) }

    deinit { drmModeFreePlane(ptr) }
}

/// Owns a `drmModePlaneRes` (plane inventory) and frees it on teardown.
struct DrmPlaneResources: ~Copyable {
    private let ptr: drmModePlaneResPtr

    init?(fd: Int32) {
        guard let p = drmModeGetPlaneResources(fd) else { return nil }
        self.ptr = p
    }

    var planeIds: [UInt32] { idArray(ptr.pointee.planes, ptr.pointee.count_planes) }

    deinit { drmModeFreePlaneResources(ptr) }
}

/// Owns a `drmModePropertyBlob` (e.g. a MODE_ID or GAMMA_LUT blob) and frees it
/// on teardown. Copies the blob bytes out on demand.
struct DrmPropertyBlob: ~Copyable {
    private let ptr: drmModePropertyBlobPtr

    init?(fd: Int32, blobId: UInt32) {
        guard let p = drmModeGetPropertyBlob(fd, blobId) else { return nil }
        self.ptr = p
    }

    var id: UInt32 { ptr.pointee.id }
    var length: UInt32 { ptr.pointee.length }

    var bytes: [UInt8] {
        let len = Int(ptr.pointee.length)
        guard len > 0, let data = ptr.pointee.data else { return [] }
        return Array(UnsafeRawBufferPointer(start: data, count: len))
    }

    deinit { drmModeFreePropertyBlob(ptr) }
}

// MARK: - Property enumeration

/// One property of a KMS object: its id, current value, and name. Value type,
/// copied out before the libdrm results that produced it are freed.
struct DrmPropertyEntry: Sendable, Equatable {
    var id: UInt32
    var value: UInt64
    var name: String
}

/// KMS object kinds the property enumeration runs against.
enum DrmObjectKind: UInt32 {
    case connector = 0xc0c0_c0c0  // DRM_MODE_OBJECT_CONNECTOR
    case crtc = 0xcccc_cccc       // DRM_MODE_OBJECT_CRTC
    case plane = 0xeeee_eeee      // DRM_MODE_OBJECT_PLANE
}

enum DrmProperties {
    /// Project an object's properties into value-typed entries: one
    /// `drmModeObjectGetProperties` for the
    /// id/value pairs, then one `drmModeGetProperty` per id for the name.
    /// Returns an empty array when the object has no properties or the query
    /// fails (a fail-soft convention).
    static func enumerate(fd: Int32, objectId: UInt32, kind: DrmObjectKind) -> [DrmPropertyEntry] {
        guard let props = drmModeObjectGetProperties(fd, objectId, kind.rawValue) else { return [] }
        defer { drmModeFreeObjectProperties(props) }

        let count = Int(props.pointee.count_props)
        guard count > 0,
              let ids = props.pointee.props,
              let values = props.pointee.prop_values else { return [] }

        var entries: [DrmPropertyEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let propId = ids[i]
            guard let prop = drmModeGetProperty(fd, propId) else { continue }
            defer { drmModeFreeProperty(prop) }
            var rawName = prop.pointee.name
            let name = withUnsafeBytes(of: &rawName) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            entries.append(DrmPropertyEntry(id: propId, value: values[i], name: name))
        }
        return entries
    }

    /// Resolve a property id by name on a live object (0 when absent), mirroring
    /// `findProperty`.
    static func findId(fd: Int32, objectId: UInt32, kind: DrmObjectKind, name: String) -> UInt32 {
        findId(in: enumerate(fd: fd, objectId: objectId, kind: kind), name: name)
    }

    /// Resolve a property value by name on a live object (nil when absent),
    /// mirroring `getObjectPropertyValue`.
    static func findValue(fd: Int32, objectId: UInt32, kind: DrmObjectKind, name: String) -> UInt64? {
        findValue(in: enumerate(fd: fd, objectId: objectId, kind: kind), name: name)
    }

    // Pure matching over already-projected entries — testable without hardware.

    /// First matching property id, or 0 when absent (the "0 = missing"
    /// sentinel atomic-prop discovery keys on).
    static func findId(in entries: [DrmPropertyEntry], name: String) -> UInt32 {
        entries.first(where: { $0.name == name })?.id ?? 0
    }

    /// First matching property value, or nil when absent.
    static func findValue(in entries: [DrmPropertyEntry], name: String) -> UInt64? {
        entries.first(where: { $0.name == name })?.value
    }
}

// MARK: - Shared helpers

/// Copy a libdrm `uint32_t *` + count into a Swift array. The `count` arrives as
/// libdrm's `int`; a negative/zero count yields an empty array.
private func idArray(_ base: UnsafeMutablePointer<UInt32>?, _ count: Int32) -> [UInt32] {
    guard count > 0, let base else { return [] }
    return Array(UnsafeBufferPointer(start: base, count: Int(count)))
}

private func idArray(_ base: UnsafeMutablePointer<UInt32>?, _ count: UInt32) -> [UInt32] {
    guard count > 0, let base else { return [] }
    return Array(UnsafeBufferPointer(start: base, count: Int(count)))
}
