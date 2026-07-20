import Testing
@testable import NucleusUI

@MainActor
@Suite(.uiContext) struct FoundationRandomizedTests {
    @Test func randomizedInvertibleViewTransformsRoundTripPoints() {
        var random = FoundationRandom(seed: 0x5452_414e_5346_4f52)
        let root = View()
        root.frame = Rect(x: 13, y: 17, width: 800, height: 600)
        let child = View()
        child.frame = Rect(x: 30, y: 40, width: 240, height: 180)
        root.addSubview(child)

        for iteration in 0..<1_000 {
            let angle = random.double(in: (-Double.pi)...Double.pi)
            let scaleX = random.double(in: 0.2...4)
            let scaleY = random.double(in: 0.2...4)
            let translationX = random.double(in: -80...80)
            let translationY = random.double(in: -80...80)
            var transform = Transform.rotation(radians: angle)
            transform.m00 *= scaleX
            transform.m01 *= scaleX
            transform.m10 *= scaleY
            transform.m11 *= scaleY
            transform.m30 = translationX
            transform.m31 = translationY
            child.transform = transform

            let local = Point(
                x: random.double(in: -120...360),
                y: random.double(in: -90...270))
            let inRoot = child.convert(local, to: root)
            let roundTrip = child.convert(inRoot, from: root)
            #expect(
                abs(roundTrip.x - local.x) < 1e-8
                    && abs(roundTrip.y - local.y) < 1e-8,
                "transform round trip failed at iteration \(iteration)")
        }
    }

    @Test func randomizedLayoutConstraintsProduceCanonicalFiniteSizes() {
        var random = FoundationRandom(seed: 0x4c41_594f_5554)
        for iteration in 0..<10_000 {
            let minWidth = random.double(in: -1_000...1_000)
            let minHeight = random.double(in: -1_000...1_000)
            let maxWidth = random.bool
                ? random.double(in: -1_000...2_000)
                : .infinity
            let maxHeight = random.bool
                ? random.double(in: -1_000...2_000)
                : .infinity
            let constraints = LayoutConstraints(
                minWidth: minWidth,
                maxWidth: maxWidth,
                minHeight: minHeight,
                maxHeight: maxHeight)
            let proposed = Size(
                width: random.bool
                    ? random.double(in: -10_000...10_000)
                    : .nan,
                height: random.bool
                    ? random.double(in: -10_000...10_000)
                    : .infinity)
            let size = constraints.constrain(proposed)
            #expect(
                size.isFinite
                    && size.width >= 0
                    && size.height >= 0
                    && size.width >= constraints.minWidth
                    && size.height >= constraints.minHeight,
                "noncanonical layout result at iteration \(iteration)")
            #expect(
                !constraints.maxWidth.isFinite
                    || size.width <= constraints.maxWidth)
            #expect(
                !constraints.maxHeight.isFinite
                    || size.height <= constraints.maxHeight)
        }
    }

    @Test func randomizedTextEditingPreservesUTFSelectionAndSecureContracts() {
        var random = FoundationRandom(seed: 0x5445_5854_4544_4954)
        let fragments = ["a", " ", "😀", "e\u{301}", "🇯🇵", "日本", "\n"]
        var model = TextEditorModel()

        for iteration in 0..<5_000 {
            switch random.index(12) {
            case 0, 1:
                model.insert(fragments[random.index(fragments.count)])
            case 2:
                model.deleteBackward()
            case 3:
                model.deleteForward()
            case 4:
                model.moveCaret(random.bool ? .backward : .forward)
            case 5:
                model.moveCaret(
                    random.bool ? .wordBackward : .wordForward,
                    extendingSelection: random.bool)
            case 6:
                model.setCaret(at: random.index(model.utf16Count + 7) - 3)
            case 7:
                let first = random.index(model.utf16Count + 7) - 3
                let second = random.index(model.utf16Count + 7) - 3
                model.setSelection(TextSelection(anchor: first, head: second))
            case 8:
                let marked = fragments[random.index(fragments.count)]
                model.setMarkedText(
                    marked,
                    selectedRange: marked.utf16.isEmpty
                        ? nil
                        : marked.utf16.count..<marked.utf16.count)
            case 9:
                if model.hasMarkedText, random.bool {
                    model.commitMarkedText(
                        fragments[random.index(fragments.count)])
                } else {
                    model.unmarkText()
                }
            case 10:
                _ = random.bool ? model.undo() : model.redo()
            default:
                model.setSecure(!model.isSecure)
            }

            let probe = random.index(model.utf16Count + 7) - 3
            let alignedProbe = model.alignedOffset(probe)
            #expect(
                model.utf16Offset(
                    forUTF8: model.utf8Offset(forUTF16: alignedProbe)
                ) == alignedProbe,
                "UTF-16/UTF-8 boundary round trip failed at iteration \(iteration)")
            #expect(model.selection.anchor == model.alignedOffset(
                model.selection.anchor))
            #expect(model.selection.head == model.alignedOffset(
                model.selection.head))
            #expect(model.selection.lowerBound >= 0)
            #expect(model.selection.upperBound <= model.utf16Count)
            if let marked = model.markedRange {
                #expect(marked.lowerBound >= 0)
                #expect(marked.upperBound <= model.utf16Count)
            }
            if model.isSecure {
                #expect(model.surroundingText() == nil)
                #expect(model.copyableSelection() == nil)
                #expect(model.displayText.allSatisfy { $0 == "•" })
            }
        }
    }
}

private struct FoundationRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    var bool: Bool {
        mutating get {
            next() & 1 == 0
        }
    }

    mutating func index(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound
            + (range.upperBound - range.lowerBound) * unit
    }

    private mutating func next() -> UInt64 {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return state
    }
}
