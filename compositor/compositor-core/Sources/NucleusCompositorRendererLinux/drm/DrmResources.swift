// Swift noncopyable `drmMode*` result owners + property
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
import NucleusCompositorDrmC

// MARK: - Mode info value

/// A KMS mode, copied out of libdrm's `drmModeModeInfo` so callers never hold a
/// pointer into a `drmModeConnector`'s mode array.
struct DrmModeInfo: Sendable, Equatable {
    var clock: UInt32
    var hdisplay: UInt16
    var htotal: UInt16
    var vdisplay: UInt16
    var vtotal: UInt16
    var vscan: UInt16
    var vrefresh: UInt32
    var flags: UInt32
    var type: UInt32
    var name: String
    /// Exact bytes supplied by libdrm for MODE_ID blob creation. Synthetic policy
    /// fixtures leave this empty because they never create kernel blobs.
    private var kernelBytes: [UInt8]

    /// True for the connector's driver-preferred mode (`DRM_MODE_TYPE_PREFERRED`).
    var isPreferred: Bool { (type & UInt32(DRM_MODE_TYPE_PREFERRED)) != 0 }

    /// Refresh in millihertz, derived from the mode timings rather than the
    /// integer `vrefresh` convenience field. This preserves fractional rates.
    var refreshMilliHz: Int32 {
        guard clock > 0, htotal > 0, vtotal > 0 else {
            return Int32(clamping: UInt64(vrefresh) * 1_000)
        }
        var numerator = UInt64(clock) * 1_000_000
        var denominator = UInt64(htotal) * UInt64(vtotal)
        if (flags & UInt32(DRM_MODE_FLAG_INTERLACE)) != 0 { numerator *= 2 }
        if (flags & UInt32(DRM_MODE_FLAG_DBLSCAN)) != 0 { denominator *= 2 }
        if vscan > 1 { denominator *= UInt64(vscan) }
        let rounded = (numerator + denominator / 2) / denominator
        return Int32(clamping: rounded)
    }

    init(_ mode: drmModeModeInfo) {
        self.clock = mode.clock
        self.hdisplay = mode.hdisplay
        self.htotal = mode.htotal
        self.vdisplay = mode.vdisplay
        self.vtotal = mode.vtotal
        self.vscan = mode.vscan
        self.vrefresh = mode.vrefresh
        self.flags = mode.flags
        self.type = mode.type
        var raw = mode.name
        self.name = withUnsafeBytes(of: &raw) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        var rawMode = mode
        self.kernelBytes = withUnsafeBytes(of: &rawMode) { Array($0) }
    }

    init(
        clock: UInt32, hdisplay: UInt16, htotal: UInt16,
        vdisplay: UInt16, vtotal: UInt16, vscan: UInt16 = 0,
        vrefresh: UInt32, flags: UInt32 = 0, type: UInt32 = 0, name: String
    ) {
        self.clock = clock
        self.hdisplay = hdisplay
        self.htotal = htotal
        self.vdisplay = vdisplay
        self.vtotal = vtotal
        self.vscan = vscan
        self.vrefresh = vrefresh
        self.flags = flags
        self.type = type
        self.name = name
        self.kernelBytes = []
    }

    static func == (lhs: DrmModeInfo, rhs: DrmModeInfo) -> Bool {
        lhs.clock == rhs.clock
            && lhs.hdisplay == rhs.hdisplay
            && lhs.htotal == rhs.htotal
            && lhs.vdisplay == rhs.vdisplay
            && lhs.vtotal == rhs.vtotal
            && lhs.vscan == rhs.vscan
            && lhs.vrefresh == rhs.vrefresh
            && lhs.flags == rhs.flags
            && lhs.type == rhs.type
            && lhs.name == rhs.name
    }

    /// Create a MODE_ID property blob from the exact kernel mode record captured
    /// during discovery.
    func createModeBlob(fd: Int32) -> UInt32? {
        guard kernelBytes.count == MemoryLayout<drmModeModeInfo>.size else { return nil }
        var blobID: UInt32 = 0
        let result = kernelBytes.withUnsafeBytes {
            drmModeCreatePropertyBlob(fd, $0.baseAddress, $0.count, &blobID)
        }
        return result == 0 && blobID != 0 ? blobID : nil
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
