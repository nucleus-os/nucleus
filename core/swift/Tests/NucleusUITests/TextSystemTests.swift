@testable import NucleusUI
import Testing

@MainActor
@Suite(.uiContext) struct TextSystemTests {
    final class RecordingBackend: TextLayoutBackend {
        var generation: UInt64 = 1
        var creationCount = 0
        var retainCount = 0
        var releaseCount = 0
        var glyphQueryCount = 0
        var selectionQueryCount = 0

        func resolveFont(
            _ descriptor: FontDescriptor
        ) -> ResolvedFontDescriptor? {
            ResolvedFontDescriptor(
                familyName: descriptor.familyName ?? "Test",
                postScriptName: "Test",
                pointSize: descriptor.pointSize,
                weight: descriptor.weight,
                width: descriptor.width,
                slant: descriptor.slant
            )
        }

        func fontMetrics(for descriptor: FontDescriptor) -> FontMetrics? {
            FontMetrics(
                ascender: 8,
                descender: 2,
                leading: 1,
                capHeight: 7,
                xHeight: 5
            )
        }

        func createLayout(
            _ attributedText: AttributedText,
            containerWidth: Double?,
            paragraphStyle: ParagraphStyle,
            scale: Float
        ) -> TextBackendLayout? {
            creationCount += 1
            return TextBackendLayout(
                handle: TextLayoutHandle(rawValue: UInt64(creationCount)),
                usedRect: Rect(x: 0, y: 0, width: 40, height: 10),
                lines: [
                    TextLayoutLine(
                        text: attributedText.string,
                        frame: Rect(x: 0, y: 0, width: 40, height: 10),
                        baselineOffsetFromTop: 8
                    ),
                ]
            )
        }

        func retainLayout(_ handle: TextLayoutHandle) {
            retainCount += 1
        }

        func releaseLayout(_ handle: TextLayoutHandle) {
            releaseCount += 1
        }

        func glyphPosition(
            at point: Point,
            in handle: TextLayoutHandle
        ) -> TextGlyphPosition? {
            glyphQueryCount += 1
            return TextGlyphPosition(utf16Offset: 1)
        }

        func caretGeometry(
            atUTF16Offset offset: Int,
            affinity: TextAffinity,
            in handle: TextLayoutHandle
        ) -> TextCaretGeometry? {
            TextCaretGeometry(
                rect: Rect(x: Double(offset) * 4, y: 0, width: 1, height: 10),
                affinity: affinity
            )
        }

        func selectionRects(
            forUTF16Range range: Range<Int>,
            in handle: TextLayoutHandle
        ) -> [TextSelectionRect]? {
            selectionQueryCount += 1
            return [
                TextSelectionRect(rect: Rect(
                    x: Double(range.lowerBound) * 4,
                    y: 0,
                    width: Double(range.count) * 4,
                    height: 10
                )),
            ]
        }
    }

    @Test func oneMeasuredResourceServicesEveryGeometryQuery() throws {
        let system = TextSystem()
        let backend = RecordingBackend()
        system.installBackend(backend)

        var result: TextLayoutResult? = system.layout(
            AttributedText(
                "hello",
                style: TextStyle(font: .systemFont(ofSize: 12))
            ),
            containerWidth: 100,
            paragraphStyle: ParagraphStyle()
        )
        let storage = try #require(result?.storage)

        #expect(storage.glyphPosition(at: Point(x: 3, y: 2))?.utf16Offset == 1)
        #expect(storage.glyphPosition(at: Point(x: 7, y: 2))?.utf16Offset == 1)
        #expect(storage.selectionRects(forUTF16Range: 1..<3)?.count == 1)
        #expect(storage.caretGeometry(
            atUTF16Offset: 2,
            affinity: .upstream
        )?.affinity == .upstream)
        #expect(backend.creationCount == 1)
        #expect(backend.glyphQueryCount == 2)
        #expect(backend.selectionQueryCount == 1)
        #expect(backend.releaseCount == 0)

        result = nil
        withExtendedLifetime(storage) {}
        #expect(backend.releaseCount == 0)
    }

    @Test func ownedLayoutReleasesExactlyOnceOnTheMainActor() {
        let system = TextSystem()
        let backend = RecordingBackend()
        system.installBackend(backend)

        do {
            let result = system.layout(
                AttributedText(
                    "hello",
                    style: TextStyle(font: .systemFont(ofSize: 12))
                ),
                containerWidth: nil,
                paragraphStyle: ParagraphStyle()
            )
            #expect(backend.releaseCount == 0)
            withExtendedLifetime(result) {}
        }
        #expect(backend.releaseCount == 1)
    }

    @Test func missingBackendReportsAndUsesDeterministicFallback() {
        let system = TextSystem()
        var issues: [TextSystemIssue] = []
        system.diagnosticHandler = { issues.append($0) }

        let first = system.layout(
            AttributedText(
                "fallback",
                style: TextStyle(font: .systemFont(ofSize: 10))
            ),
            containerWidth: nil,
            paragraphStyle: ParagraphStyle()
        )
        let second = system.layout(
            AttributedText(
                "fallback",
                style: TextStyle(font: .systemFont(ofSize: 10))
            ),
            containerWidth: nil,
            paragraphStyle: ParagraphStyle()
        )

        #expect(first == second)
        #expect(first.usedRect.size.width > 0)
        #expect(issues == [.missingBackend])
    }
}
