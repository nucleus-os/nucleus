// Swift scanout format/modifier model + intersection.
//
// `FormatModifiers`/`FormatSet` are the per-fourcc capability records
// (the three formats Nucleus advertises). `collectPlaneFormats`
// reads a plane's format list + its IN_FORMATS modifier blob through the
// noncopyable result owners; `selectScanoutFormat` intersects the plane's and the
// renderer's importable formats into one scanout choice.

import NucleusCompositorDrmC

// MARK: - fourcc constants

/// `DRM_FORMAT_MOD_INVALID` — the implicit-modifier sentinel.
let drmFormatModInvalid: UInt64 = 0x00ff_ffff_ffff_ffff

private func fourcc(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
    UInt32(a) | (UInt32(b) << 8) | (UInt32(c) << 16) | (UInt32(d) << 24)
}

let drmFormatXRGB8888 = fourcc(0x58, 0x52, 0x32, 0x34)      // 'X','R','2','4'
let drmFormatXBGR8888 = fourcc(0x58, 0x42, 0x32, 0x34)      // 'X','B','2','4'
let drmFormatARGB8888 = fourcc(0x41, 0x52, 0x32, 0x34)      // 'A','R','2','4' (cursor plane)
let drmFormatABGR2101010 = fourcc(0x41, 0x42, 0x33, 0x30)   // 'A','B','3','0'

func drmFormatName(_ format: UInt32) -> String {
    switch format {
    case drmFormatABGR2101010: return "ABGR2101010"
    case drmFormatXRGB8888: return "XRGB8888"
    case drmFormatXBGR8888: return "XBGR8888"
    default: return "unknown"
    }
}

// MARK: - Format capability records

let maxFormatModifiers = 128

/// The explicit modifier list + implicit flag for one fourcc.
struct FormatModifiers: Sendable, Equatable {
    var supported = false
    var implicit = false
    var modifiers: [UInt64] = []

    var count: Int { modifiers.count }

    mutating func add(_ modifier: UInt64) {
        supported = true
        if modifier == drmFormatModInvalid {
            implicit = true
            return
        }
        if contains(modifier) || modifiers.count >= maxFormatModifiers { return }
        modifiers.append(modifier)
    }

    func contains(_ modifier: UInt64) -> Bool {
        if modifier == drmFormatModInvalid { return implicit }
        return modifiers.contains(modifier)
    }
}

/// Per-fourcc capability records for the formats Nucleus advertises. Unknown
/// fourcc values return nil (no aliasing to XRGB8888).
struct FormatSet: Sendable, Equatable {
    var abgr2101010 = FormatModifiers()
    var xrgb8888 = FormatModifiers()
    var xbgr8888 = FormatModifiers()

    func get(_ format: UInt32) -> FormatModifiers? {
        switch format {
        case drmFormatABGR2101010: return abgr2101010
        case drmFormatXRGB8888: return xrgb8888
        case drmFormatXBGR8888: return xbgr8888
        default: return nil
        }
    }

    mutating func add(_ format: UInt32, _ modifier: UInt64) {
        switch format {
        case drmFormatABGR2101010: abgr2101010.add(modifier)
        case drmFormatXRGB8888: xrgb8888.add(modifier)
        case drmFormatXBGR8888: xbgr8888.add(modifier)
        default: break
        }
    }

    func supportsFormatModifier(_ format: UInt32, _ modifier: UInt64) -> Bool {
        guard let mods = get(format), mods.supported else { return false }
        if mods.count == 0 { return mods.implicit || modifier == 0 || modifier == drmFormatModInvalid }
        return mods.contains(modifier)
    }
}

// MARK: - Scanout choice

/// The format + modifier list a scanout swapchain allocates against.
struct ScanoutFormat: Sendable, Equatable {
    var format: UInt32 = drmFormatXRGB8888
    var modifiers: [UInt64] = []
    var useModifiers = false
}

/// The format preference order — 8-bit XRGB first (avoids HDMI/Nvidia color
/// issues with 10-bit), 10-bit ABGR as fallback.
let scanoutFormatPreference: [UInt32] = [drmFormatXRGB8888, drmFormatABGR2101010]

/// Intersect the plane's and the renderer's modifier lists for one format into a
/// scanout choice, or nil if they don't overlap. Pure (the `intersectFormatModifiers`
/// logic): explicit modifiers preferred when `allowModifiers`, implicit as fallback.
func intersectFormatModifiers(
    format: UInt32,
    planeMods: FormatModifiers,
    importMods: FormatModifiers,
    allowModifiers: Bool
) -> ScanoutFormat? {
    guard planeMods.supported, importMods.supported else { return nil }

    if allowModifiers {
        var shared: [UInt64] = []
        for modifier in planeMods.modifiers where importMods.contains(modifier) {
            shared.append(modifier)
            if shared.count >= maxFormatModifiers { break }
        }
        if !shared.isEmpty {
            return ScanoutFormat(format: format, modifiers: shared, useModifiers: true)
        }
    }

    if planeMods.implicit, importMods.implicit {
        return ScanoutFormat(format: format, modifiers: [], useModifiers: false)
    }
    return nil
}

/// Choose a scanout format by intersecting plane + importable formats in
/// preference order. Mirrors `selectScanoutFormat`.
func selectScanoutFormat(
    planeFormats: FormatSet,
    importFormats: FormatSet,
    allowModifiers: Bool
) -> ScanoutFormat? {
    for format in scanoutFormatPreference {
        guard let planeMods = planeFormats.get(format),
              let importMods = importFormats.get(format) else { continue }
        if let choice = intersectFormatModifiers(
            format: format, planeMods: planeMods, importMods: importMods, allowModifiers: allowModifiers) {
            return choice
        }
    }
    return nil
}

/// Choose the next scanout format after `current` in preference order — the
/// recovery fallback when the current format stops importing. Mirrors
/// `fallbackScanoutFormatAfter`.
func fallbackScanoutFormat(
    after current: UInt32,
    planeFormats: FormatSet,
    importFormats: FormatSet,
    allowModifiers: Bool
) -> ScanoutFormat? {
    var passedCurrent = false
    for format in scanoutFormatPreference {
        if !passedCurrent {
            passedCurrent = (format == current)
            continue
        }
        guard let planeMods = planeFormats.get(format),
              let importMods = importFormats.get(format) else { continue }
        if let choice = intersectFormatModifiers(
            format: format, planeMods: planeMods, importMods: importMods, allowModifiers: allowModifiers) {
            return choice
        }
    }
    return nil
}

// MARK: - IN_FORMATS blob parsing + plane collection

/// One (format, modifier) pair decoded from an IN_FORMATS blob.
struct FormatModifierPair: Sendable, Equatable {
    var format: UInt32
    var modifier: UInt64
}

/// Parse a KMS `IN_FORMATS` property blob into its (format, modifier) pairs.
/// Pure — the blob layout (`drm_format_modifier_blob` header + format array +
/// modifier-bitmask table) decoded from raw bytes, mirroring `collectPlaneFormats`.
func parseInFormatsBlob(_ bytes: [UInt8]) -> [FormatModifierPair] {
    // Header: version(u32) flags(u32) count_formats(u32) formats_offset(u32)
    //         count_modifiers(u32) modifiers_offset(u32) = 24 bytes.
    guard bytes.count >= 24 else { return [] }
    return bytes.withUnsafeBytes { raw -> [FormatModifierPair] in
        func u32(_ off: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
        func u64(_ off: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: off, as: UInt64.self) }

        let countFormats = Int(u32(8))
        let formatsOffset = Int(u32(12))
        let countModifiers = Int(u32(16))
        let modifiersOffset = Int(u32(20))

        // Bounds-check the two tables before walking them.
        guard formatsOffset + countFormats * 4 <= bytes.count,
              modifiersOffset + countModifiers * 24 <= bytes.count else { return [] }

        func formatAt(_ index: Int) -> UInt32 { u32(formatsOffset + index * 4) }

        var pairs: [FormatModifierPair] = []
        for mi in 0..<countModifiers {
            // drm_format_modifier: formats(u64) offset(u32) pad(u32) modifier(u64).
            let base = modifiersOffset + mi * 24
            let formatsMask = u64(base)
            let bitOffset = Int(u32(base + 8))
            let modifier = u64(base + 16)
            for bit in 0..<64 where (formatsMask & (UInt64(1) << bit)) != 0 {
                let formatIndex = bitOffset + bit
                guard formatIndex < countFormats else { continue }
                pairs.append(FormatModifierPair(format: formatAt(formatIndex), modifier: modifier))
            }
        }
        return pairs
    }
}

/// Collect a plane's advertised formats + IN_FORMATS modifiers into a FormatSet,
/// through the Phase 10a.2 result owners. Mirrors `collectPlaneFormats`.
func collectPlaneFormats(fd: Int32, planeId: UInt32) -> FormatSet {
    var formats = FormatSet()

    guard let plane = DrmPlane(fd: fd, planeId: planeId) else { return formats }
    for format in plane.formats {
        formats.add(format, drmFormatModInvalid)
    }

    let blobId = DrmProperties.findValue(fd: fd, objectId: planeId, kind: .plane, name: "IN_FORMATS") ?? 0
    guard blobId != 0, let blob = DrmPropertyBlob(fd: fd, blobId: UInt32(truncatingIfNeeded: blobId)) else {
        return formats
    }
    for pair in parseInFormatsBlob(blob.bytes) {
        formats.add(pair.format, pair.modifier)
    }
    return formats
}
