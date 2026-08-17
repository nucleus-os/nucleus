import NucleusCompositorDrmC
import Testing

@testable import NucleusCompositorRendererLinux
@testable import NucleusRenderer

// scanout intersection + IN_FORMATS blob parsing — all hardware-independent. The
// fixture's best-effort real-KMS exercise (which asserted nothing) is dropped.
@Suite struct DrmFormatsTests {
    /// Build a synthetic IN_FORMATS blob: `formats` listed, then one modifier
    /// entry whose bitmask covers all of them with `modifier`.
    static func synthBlob(formats: [UInt32], modifier: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        func putU32(_ v: UInt32) {
            for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
        }
        func putU64(_ v: UInt64) {
            for i in 0..<8 { out.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
        }
        let headerLen = 24
        let formatsOffset = headerLen
        let modifiersOffset = headerLen + formats.count * 4
        putU32(1)
        putU32(0)
        putU32(UInt32(formats.count))
        putU32(UInt32(formatsOffset))
        putU32(1)
        putU32(UInt32(modifiersOffset))
        for f in formats { putU32(f) }
        var mask: UInt64 = 0
        for i in 0..<formats.count { mask |= (UInt64(1) << i) }
        putU64(mask)
        putU32(0)
        putU32(0)
        putU64(modifier)
        return out
    }

    @Test func formatModifierModel() {
        var fm = FormatModifiers()
        fm.add(drmFormatModInvalid)
        #expect(fm.supported && fm.implicit && fm.count == 0)
        fm.add(0x100)
        fm.add(0x100)
        fm.add(0x200)
        #expect(fm.count == 2 && fm.contains(0x100) && fm.contains(0x200))
        #expect(fm.contains(drmFormatModInvalid))

        var set = FormatSet()
        #expect(set.get(0xdead_beef) == nil && set.get(drmFormatXRGB8888) != nil)
        set.add(drmFormatXRGB8888, drmFormatModInvalid)
        #expect(set.supportsFormatModifier(drmFormatXRGB8888, drmFormatModInvalid))
        #expect(!set.supportsFormatModifier(0xdead_beef, drmFormatModInvalid))
    }

    @Test func scanoutIntersection() {
        var plane = FormatSet()
        plane.add(drmFormatXRGB8888, 0x100)
        plane.add(drmFormatXRGB8888, 0x200)
        var imp = FormatSet()
        imp.add(drmFormatXRGB8888, 0x200)
        imp.add(drmFormatXRGB8888, 0x300)
        let choice = selectScanoutFormat(
            planeFormats: plane, importFormats: imp, allowModifiers: true)
        #expect(
            choice?.format == drmFormatXRGB8888 && choice?.useModifiers == true
                && choice?.modifiers == [0x200])

        var planeImp = FormatSet()
        planeImp.add(drmFormatXRGB8888, drmFormatModInvalid)
        var impImp = FormatSet()
        impImp.add(drmFormatXRGB8888, drmFormatModInvalid)
        let implicitChoice = selectScanoutFormat(
            planeFormats: planeImp, importFormats: impImp, allowModifiers: false)
        #expect(
            implicitChoice?.useModifiers == false && implicitChoice?.format == drmFormatXRGB8888)

        var planeA = FormatSet()
        planeA.add(drmFormatXRGB8888, 0x100)
        var impB = FormatSet()
        impB.add(drmFormatXRGB8888, 0x999)
        #expect(
            selectScanoutFormat(planeFormats: planeA, importFormats: impB, allowModifiers: true)
                == nil)

        var planeBoth = FormatSet()
        planeBoth.add(drmFormatXRGB8888, 0x5)
        planeBoth.add(drmFormatABGR2101010, 0x5)
        #expect(
            selectScanoutFormat(
                planeFormats: planeBoth, importFormats: planeBoth, allowModifiers: true)?.format
                == drmFormatXRGB8888)
        let fb = fallbackScanoutFormat(
            after: drmFormatXRGB8888, planeFormats: planeBoth, importFormats: planeBoth,
            allowModifiers: true)
        #expect(fb?.format == drmFormatABGR2101010)
    }

    @Test func inFormatsBlobParse() {
        let blob = Self.synthBlob(
            formats: [drmFormatXRGB8888, drmFormatABGR2101010], modifier: 0x1234)
        let pairs = parseInFormatsBlob(blob)
        #expect(pairs.count == 2)
        #expect(pairs.contains(FormatModifierPair(format: drmFormatXRGB8888, modifier: 0x1234)))
        #expect(pairs.contains(FormatModifierPair(format: drmFormatABGR2101010, modifier: 0x1234)))
        #expect(parseInFormatsBlob(Array(blob.prefix(10))).isEmpty)
    }

    @Test func inFormatsBlobRejectsOversizedTablesAndTruncatedRecords() {
        var oversizedFormats = Self.synthBlob(formats: [drmFormatXRGB8888], modifier: 7)
        Self.replaceU32(.max, at: 8, in: &oversizedFormats)
        #expect(parseInFormatsBlob(oversizedFormats).isEmpty)

        var oversizedModifiers = Self.synthBlob(formats: [drmFormatXRGB8888], modifier: 7)
        Self.replaceU32(.max, at: 16, in: &oversizedModifiers)
        #expect(parseInFormatsBlob(oversizedModifiers).isEmpty)

        let valid = Self.synthBlob(formats: [drmFormatXRGB8888], modifier: 7)
        #expect(parseInFormatsBlob(Array(valid.dropLast())).isEmpty)
    }

    static func replaceU32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index)))
        }
    }
}
