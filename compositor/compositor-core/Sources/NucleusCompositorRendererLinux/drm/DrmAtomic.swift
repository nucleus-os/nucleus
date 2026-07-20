// Swift atomic-commit builder + atomic property groups over real
// libdrm.
//
// `AtomicRequestBuilder` owns the opaque libdrm `drmModeAtomicReq` (alloc on
// init, free on `deinit`) and, alongside populating it through
// `drmModeAtomicAddProperty`, records a typed labelled entry per property. The
// typed shadow is what makes validation and the failed-request diagnostic dump
// possible — the opaque request the kernel sees is unreadable, so the builder
// keeps the (object, property, value, label) triples so a
// rejected commit names which property failed.
//
// `AtomicProps` / `PlaneAtomicProps` are the cached property-ID groups one
// output pipeline commits through. Discovery
// resolves each ID by name through `DrmProperties`; the pure
// `discover(connector:crtc:plane:)` overload and `hasRequired` gates are exercised
// without DRM hardware.

import NucleusCompositorDrmC

// MARK: - Atomic request builder

/// Builds one atomic commit: populates the opaque libdrm `drmModeAtomicReq`
/// while recording a typed labelled shadow of every property for validation and
/// the failed-request diagnostic dump. Noncopyable — one owner, freed once.
struct AtomicRequestBuilder: ~Copyable {
    /// One recorded property assignment. The label (e.g. "plane.FB_ID") names
    /// the property in a rejection dump where only opaque IDs are otherwise
    /// visible.
    struct Entry: Sendable, Equatable {
        var objectId: UInt32
        var propertyId: UInt32
        var value: UInt64
        var label: String
    }

    private let req: drmModeAtomicReqPtr
    private(set) var entries: [Entry] = []

    init?() {
        guard let r = drmModeAtomicAlloc() else { return nil }
        self.req = r
    }

    var count: Int { entries.count }

    /// Record and stage one property. Returns false if libdrm rejected the add
    /// (it grows the request on the C side); the typed entry is recorded
    /// regardless so a failed build still dumps what was attempted.
    @discardableResult
    mutating func add(objectId: UInt32, propertyId: UInt32, value: UInt64, label: String) -> Bool {
        let rc = drmModeAtomicAddProperty(req, objectId, propertyId, value)
        entries.append(Entry(objectId: objectId, propertyId: propertyId, value: value, label: label))
        return rc >= 0
    }

    /// Submit the staged request. Returns libdrm's result (0 on success, a
    /// negative errno otherwise). `flags` carries `DRM_MODE_ATOMIC_*` /
    /// `DRM_MODE_PAGE_FLIP_*`; `userData` is handed back on the page-flip event.
    borrowing func commit(fd: Int32, flags: UInt32, userData: UnsafeMutableRawPointer? = nil) -> Int32 {
        drmModeAtomicCommit(fd, req, flags, userData)
    }

    /// Validate the staged request as a kernel test-only commit (no scanout
    /// change). True when the kernel would accept it.
    borrowing func validates(fd: Int32) -> Bool {
        drmModeAtomicCommit(fd, req, UInt32(DRM_MODE_ATOMIC_TEST_ONLY), nil) == 0
    }

    /// The labelled property dump for a rejected commit — the recorded
    /// (object, property, value) triples with the property label prepended.
    borrowing func diagnosticLines() -> [String] {
        entries.enumerated().map { index, entry in
            "atomic[\(index)]: \(entry.label) obj=\(entry.objectId) prop=\(entry.propertyId) value=0x\(String(entry.value, radix: 16))"
        }
    }

    deinit { drmModeAtomicFree(req) }
}

// MARK: - Atomic property groups

/// The plane property IDs an atomic commit assigns. 0 means the property is
/// absent on this plane.
struct PlaneAtomicProps: Sendable, Equatable {
    var fbId: UInt32 = 0
    var crtcId: UInt32 = 0
    var srcX: UInt32 = 0
    var srcY: UInt32 = 0
    var srcW: UInt32 = 0
    var srcH: UInt32 = 0
    var crtcX: UInt32 = 0
    var crtcY: UInt32 = 0
    var crtcW: UInt32 = 0
    var crtcH: UInt32 = 0
    var inFenceFd: UInt32 = 0
    var colorRange: UInt32 = 0

    /// The geometry + framebuffer props a scanout commit cannot omit. IN_FENCE_FD
    /// and COLOR_RANGE are optional.
    var hasRequired: Bool {
        fbId != 0 && crtcId != 0 &&
            srcX != 0 && srcY != 0 && srcW != 0 && srcH != 0 &&
            crtcX != 0 && crtcY != 0 && crtcW != 0 && crtcH != 0
    }
}

/// The cached DRM atomic property metadata for one output pipeline (connector +
/// CRTC + primary plane). Property ids use 0 for absence. `crtcGammaLutSize`
/// is the immutable value of `GAMMA_LUT_SIZE`, not a property id.
struct AtomicProps: Sendable, Equatable {
    var connCrtcId: UInt32 = 0
    var connBroadcastRgb: UInt32 = 0
    var crtcActive: UInt32 = 0
    var crtcModeId: UInt32 = 0
    var crtcVrrEnabled: UInt32 = 0
    var crtcOutFencePtr: UInt32 = 0
    var crtcGammaLut: UInt32 = 0
    var crtcGammaLutSize: UInt32 = 0
    var crtcDegammaLut: UInt32 = 0
    var crtcCtm: UInt32 = 0
    var planeFbId: UInt32 = 0
    var planeCrtcId: UInt32 = 0
    var planeSrcX: UInt32 = 0
    var planeSrcY: UInt32 = 0
    var planeSrcW: UInt32 = 0
    var planeSrcH: UInt32 = 0
    var planeCrtcX: UInt32 = 0
    var planeCrtcY: UInt32 = 0
    var planeCrtcW: UInt32 = 0
    var planeCrtcH: UInt32 = 0
    var planeInFenceFd: UInt32 = 0
    var planeColorRange: UInt32 = 0

    /// The primary-plane subset, mirroring `primaryPlaneProps`.
    var primaryPlaneProps: PlaneAtomicProps {
        PlaneAtomicProps(
            fbId: planeFbId, crtcId: planeCrtcId,
            srcX: planeSrcX, srcY: planeSrcY, srcW: planeSrcW, srcH: planeSrcH,
            crtcX: planeCrtcX, crtcY: planeCrtcY, crtcW: planeCrtcW, crtcH: planeCrtcH,
            inFenceFd: planeInFenceFd, colorRange: planeColorRange)
    }

    /// The minimum property set a modeset+scanout commit needs.
    var hasRequired: Bool {
        connCrtcId != 0 && crtcActive != 0 && crtcModeId != 0 && primaryPlaneProps.hasRequired
    }
}

enum AtomicPropsDiscovery {
    /// Resolve the pipeline's atomic property IDs from already-enumerated
    /// per-object property entries. Pure — the testable seam mirroring
    /// `discoverAtomicProps`, keyed on the exact KMS property names.
    static func discover(
        connector: [DrmPropertyEntry],
        crtc: [DrmPropertyEntry],
        plane: [DrmPropertyEntry]
    ) -> AtomicProps {
        func findConn(_ name: String) -> UInt32 { DrmProperties.findId(in: connector, name: name) }
        func findCrtc(_ name: String) -> UInt32 { DrmProperties.findId(in: crtc, name: name) }
        func findCrtcValue(_ name: String) -> UInt32 {
            guard let value = DrmProperties.findValue(in: crtc, name: name),
                  let narrowed = UInt32(exactly: value) else { return 0 }
            return narrowed
        }
        func findPlane(_ name: String) -> UInt32 { DrmProperties.findId(in: plane, name: name) }
        return AtomicProps(
            connCrtcId: findConn("CRTC_ID"),
            connBroadcastRgb: findConn("Broadcast RGB"),
            crtcActive: findCrtc("ACTIVE"),
            crtcModeId: findCrtc("MODE_ID"),
            crtcVrrEnabled: findCrtc("VRR_ENABLED"),
            crtcOutFencePtr: findCrtc("OUT_FENCE_PTR"),
            crtcGammaLut: findCrtc("GAMMA_LUT"),
            crtcGammaLutSize: findCrtcValue("GAMMA_LUT_SIZE"),
            crtcDegammaLut: findCrtc("DEGAMMA_LUT"),
            crtcCtm: findCrtc("CTM"),
            planeFbId: findPlane("FB_ID"),
            planeCrtcId: findPlane("CRTC_ID"),
            planeSrcX: findPlane("SRC_X"),
            planeSrcY: findPlane("SRC_Y"),
            planeSrcW: findPlane("SRC_W"),
            planeSrcH: findPlane("SRC_H"),
            planeCrtcX: findPlane("CRTC_X"),
            planeCrtcY: findPlane("CRTC_Y"),
            planeCrtcW: findPlane("CRTC_W"),
            planeCrtcH: findPlane("CRTC_H"),
            planeInFenceFd: findPlane("IN_FENCE_FD"),
            planeColorRange: findPlane("COLOR_RANGE"))
    }

    /// Resolve the pipeline's atomic property IDs live, enumerating each object's
    /// properties once through libdrm. Mirrors `discoverAtomicProps`.
    static func discover(
        fd: Int32,
        connectorId: UInt32,
        crtcId: UInt32,
        planeId: UInt32
    ) -> AtomicProps {
        discover(
            connector: DrmProperties.enumerate(fd: fd, objectId: connectorId, kind: .connector),
            crtc: DrmProperties.enumerate(fd: fd, objectId: crtcId, kind: .crtc),
            plane: DrmProperties.enumerate(fd: fd, objectId: planeId, kind: .plane))
    }
}
