// DRM color and cursor helpers over libdrm.
//
// Two pieces: the desired gamma-LUT state machine + the R/G/B→`drm_color_lut`
// interleave + color-pipeline atomic state, and cursor-plane property discovery,
// placement math, and pixel packing. DrmOutput and DrmCursorPlane consume these
// directly in the live atomic presentation path.

import NucleusCompositorDrmC

// MARK: - Gamma LUT

/// One KMS gamma-ramp entry (`struct drm_color_lut`: red/green/blue/reserved).
/// Laid out to match the C struct so an array feeds `drmModeCreatePropertyBlob`.
struct DrmColorLut: Equatable {
    var red: UInt16 = 0
    var green: UInt16 = 0
    var blue: UInt16 = 0
    var reserved: UInt16 = 0
}

/// Per-output gamma LUT: the desired R/G/B ramp + its KMS property-blob id.
/// State machine for the wlr-gamma-control consumer.
struct GammaState {
    /// The kernel's current GAMMA_LUT blob id (0 = none). INVARIANT: mutated only
    /// through the fd-carrying `ensureBlob`/`destroyBlob`, never by the pure state
    /// mutators — so a live kernel blob is always destroyed before it is dropped.
    private(set) var desiredBlobId: UInt32 = 0
    /// Concatenated R[N], G[N], B[N] u16 samples; count == rampSize * 3.
    private(set) var desiredTable: [UInt16]?
    private(set) var desiredRampSize: Int = 0
    /// The desired ramp changed since the blob was last built; the next
    /// `ensureBlob(fd:)` destroys the stale blob and rebuilds. Kept separate from
    /// `desiredBlobId` so staging a new ramp never orphans the current kernel blob.
    private var blobDirty = false

    struct Snapshot {
        var blobId: UInt32
        var table: [UInt16]?
        var rampSize: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(blobId: desiredBlobId, table: desiredTable, rampSize: desiredRampSize)
    }

    /// Stage a new ramp (copying the samples) or clear it (nil/0). Marks the blob
    /// dirty so the next `ensureBlob(fd:)` rebuilds it; the current kernel blob is
    /// left intact (and destroyed by that reconcile) rather than orphaned here.
    /// Mirrors `stage`.
    mutating func stage(table: [UInt16]?, rampSize: Int) {
        if let table, rampSize != 0 {
            desiredTable = Array(table.prefix(rampSize * 3))
            desiredRampSize = rampSize
        } else {
            desiredTable = nil
            desiredRampSize = 0
        }
        blobDirty = true
    }

    /// Roll the desired ramp back to a snapshot. Marks the blob dirty so the next
    /// `ensureBlob(fd:)` destroys the current kernel blob and rebuilds for the
    /// restored ramp. Deliberately does NOT adopt `prev.blobId`: a blob built after
    /// the snapshot must not be leaked, and the snapshot's own id may already have
    /// been destroyed.
    mutating func restorePrevious(_ prev: Snapshot) {
        desiredTable = prev.table
        desiredRampSize = prev.rampSize
        blobDirty = true
    }

    /// Identity-reset the LUT on session resume when no gamma-control client is
    /// alive (so a stale ramp doesn't survive a VT switch). Marks dirty so the
    /// next `ensureBlob(fd:)` destroys the kernel blob. Mirrors
    /// `clearOnSessionResumeIfStale`.
    mutating func clearOnSessionResumeIfStale(clientAlive: Bool) {
        guard !clientAlive else { return }
        desiredTable = nil
        desiredRampSize = 0
        blobDirty = true
    }

    var currentBlobId: UInt32 { desiredBlobId }

    /// Interleave the concatenated R/G/B ramp into `drm_color_lut` entries. Pure;
    /// nil when no ramp is staged. Mirrors `ensureBlob`'s LUT build.
    func buildColorLut() -> [DrmColorLut]? {
        guard let table = desiredTable, desiredRampSize != 0,
              table.count >= desiredRampSize * 3 else { return nil }
        let n = desiredRampSize
        return (0..<n).map { i in
            DrmColorLut(red: table[i], green: table[n + i], blue: table[2 * n + i])
        }
    }

    /// Rebuild the KMS GAMMA_LUT blob from the staged ramp (real libdrm). A
    /// missing prop / absent ramp is a valid identity state (destroys any blob).
    /// Returns false only on a libdrm failure. Mirrors `ensureBlob`.
    mutating func ensureBlob(fd: Int32, gammaLutProp: UInt32) -> Bool {
        guard gammaLutProp != 0, let lut = buildColorLut() else {
            destroyBlob(fd: fd)
            blobDirty = false
            return true
        }
        if !blobDirty && desiredBlobId != 0 { return true }
        // Replace: destroy the stale blob (no-op if none) before building the new
        // one, so a re-staged ramp never leaks the previous kernel blob.
        destroyBlob(fd: fd)
        var blobId: UInt32 = 0
        let ok = lut.withUnsafeBytes { raw -> Bool in
            drmModeCreatePropertyBlob(fd, raw.baseAddress, raw.count, &blobId) == 0
        }
        guard ok else { return false }  // dirty stays set → retried next ensureBlob
        desiredBlobId = blobId
        blobDirty = false
        return true
    }

    mutating func destroyBlob(fd: Int32) {
        guard desiredBlobId != 0 else { return }
        _ = drmModeDestroyPropertyBlob(fd, desiredBlobId)
        desiredBlobId = 0
    }

    /// Add this output's gamma + color-pipeline KMS state to an atomic request.
    /// Optional props (id 0) are skipped. Mirrors `addToAtomicState`.
    func addToAtomicState(
        into builder: inout AtomicRequestBuilder,
        connectorId: UInt32,
        planeId: UInt32,
        crtcId: UInt32,
        props: AtomicProps,
        includePlaneState: Bool
    ) {
        func addOptional(_ objectId: UInt32, _ propId: UInt32, _ value: UInt64, _ label: String) {
            guard propId != 0 else { return }
            builder.add(objectId: objectId, propertyId: propId, value: value, label: label)
        }
        addOptional(connectorId, props.connBroadcastRgb, 1, "connector.Broadcast RGB")
        if includePlaneState {
            addOptional(planeId, props.planeColorRange, 1, "plane.COLOR_RANGE")
        }
        addOptional(crtcId, props.crtcGammaLut, UInt64(desiredBlobId), "crtc.GAMMA_LUT")
        addOptional(crtcId, props.crtcDegammaLut, 0, "crtc.DEGAMMA_LUT")
        addOptional(crtcId, props.crtcCtm, 0, "crtc.CTM")
    }
}

// MARK: - Cursor plane

/// The cursor plane's KMS property ids. Mirrors `cursor.PlaneProps`.
struct CursorPlaneProps: Sendable, Equatable {
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

    static func discover(fd: Int32, planeId: UInt32) -> CursorPlaneProps {
        let entries = DrmProperties.enumerate(fd: fd, objectId: planeId, kind: .plane)
        func id(_ name: String) -> UInt32 { DrmProperties.findId(in: entries, name: name) }
        return CursorPlaneProps(
            fbId: id("FB_ID"), crtcId: id("CRTC_ID"),
            srcX: id("SRC_X"), srcY: id("SRC_Y"), srcW: id("SRC_W"), srcH: id("SRC_H"),
            crtcX: id("CRTC_X"), crtcY: id("CRTC_Y"), crtcW: id("CRTC_W"), crtcH: id("CRTC_H"))
    }
}

/// An output's logical placement rectangle (compositor coordinates).
struct OutputRect: Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

/// The computed cursor-plane geometry for an atomic commit.
struct CursorPlacement: Sendable, Equatable {
    var crtcX: Int64
    var crtcY: Int64
    /// 16.16 fixed-point source size.
    var srcW: UInt64
    var srcH: UInt64
    var crtcW: UInt32
    var crtcH: UInt32
}

/// Compute the cursor plane's destination geometry, or nil when the cursor is
/// outside this output. Mirrors `cursor.Plane.addAtomicState`'s position math:
/// clamp to the output rect, scale into device pixels, offset by the hotspot,
/// and present the source size as 16.16 fixed point.
func cursorPlanePlacement(
    rect: OutputRect,
    fractionalScale: Double,
    cursorX: Double,
    cursorY: Double,
    hotspotX: Int32,
    hotspotY: Int32,
    width: UInt32,
    height: UInt32
) -> CursorPlacement? {
    guard cursorX >= rect.x, cursorX < rect.maxX, cursorY >= rect.y, cursorY < rect.maxY else {
        return nil
    }
    let cx = Int64((cursorX - rect.x) * fractionalScale)  // truncates toward zero
    let cy = Int64((cursorY - rect.y) * fractionalScale)
    return CursorPlacement(
        crtcX: cx - Int64(hotspotX),
        crtcY: cy - Int64(hotspotY),
        srcW: UInt64(width) << 16,
        srcH: UInt64(height) << 16,
        crtcW: width,
        crtcH: height)
}

/// Pack a cursor image into a destination buffer of `dstStride × dstHeight`
/// bytes (zero-filled, ARGB8888), clamping the source to the destination. Pure;
/// mirrors `CursorBuffer.upload`'s row copy.
func packCursorPixels(
    source: [UInt8],
    sourceWidth: Int,
    sourceHeight: Int,
    destinationStride: Int,
    destinationWidth: Int,
    destinationHeight: Int
) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: destinationStride * destinationHeight)
    let copyW = min(sourceWidth, destinationWidth)
    let copyH = min(sourceHeight, destinationHeight)
    let sourceStride = sourceWidth * 4
    let rowBytes = copyW * 4
    guard rowBytes > 0 else { return out }
    for y in 0..<copyH {
        let srcOffset = y * sourceStride
        let dstOffset = y * destinationStride
        guard srcOffset + rowBytes <= source.count, dstOffset + rowBytes <= out.count else { break }
        for b in 0..<rowBytes {
            out[dstOffset + b] = source[srcOffset + b]
        }
    }
    return out
}
