import Foundation
import NucleusBenchmarkSupport
import NucleusUI

@MainActor
func textAndCollectionBenchmarks() -> [BenchmarkWorkload] {
    [
        textDocumentWorkload(paragraphCount: 2_000),
        collectionWorkload(itemCount: 10_000),
    ]
}

@MainActor
private func textDocumentWorkload(paragraphCount: Int) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "text",
        name: "multiline-local-edits-\(paragraphCount)",
        inputSize: UInt64(paragraphCount),
        seed: 0x5445_5854_444f_4353,
        budgets: [
            .exact("paragraphs", UInt64(paragraphCount)),
            .maximum("initial_layout_creations", 64),
            .maximum("cached_paragraphs", 64),
            .maximum("allocation_units", UInt64(paragraphCount + 66)),
            .exact("live_backend_layouts_after_teardown", 0),
        ],
        body: {
            let backend = BenchmarkTextBackend()
            let textSystem = TextSystem()
            textSystem.installBackend(backend)
            let uiContext = UIContext(services: UIHostServices(
                textSystem: textSystem,
                pasteboard: Pasteboard(adapter: InMemoryPasteboardAdapter()),
                imageSourceResolver: .directResourcesOnly,
                diagnosticSink: { _ in }))
            let document = (0..<paragraphCount).map {
                "paragraph \($0): deterministic retained text content"
            }.joined(separator: "\n")
            let sourceBytes = UInt64(document.utf8.count)
            var metrics: [String: UInt64] = [:]
            var checksum: UInt64 = 0x5445_5854

            try uiContext.construct {
                var retainedEditor: TextView? = TextView(string: document)
                guard let editor = retainedEditor else {
                    throw BenchmarkFailure.semantic("text editor construction failed")
                }
                editor.frame = Rect(x: 0, y: 0, width: 640, height: 480)
                editor.layoutIfNeeded()
                editor.prepareVisibleParagraphLayouts()
                let initialCreations = editor.paragraphLayoutCreationCount
                let initialIDs = editor.paragraphIDs
                guard initialIDs.count == paragraphCount else {
                    throw BenchmarkFailure.semantic(
                        "text paragraph split produced \(initialIDs.count), "
                            + "expected \(paragraphCount)")
                }

                let middle = document.utf16.count / 2
                for offset in [0, middle, editor.stringValue.utf16.count] {
                    let clamped = min(offset, editor.stringValue.utf16.count)
                    editor.setSelectedRange(clamped..<clamped)
                    editor.insertText("x")
                    editor.layoutIfNeeded()
                    editor.prepareVisibleParagraphLayouts()
                }
                let afterEdits = editor.paragraphLayoutCreationCount

                editor.frame = Rect(x: 0, y: 0, width: 420, height: 480)
                editor.layoutIfNeeded()
                editor.prepareVisibleParagraphLayouts()
                let afterWidth = editor.paragraphLayoutCreationCount

                editor.contentOffset = Point(
                    x: 0,
                    y: max(0, editor.contentSize.height * 0.5))
                editor.prepareVisibleParagraphLayouts()
                let afterScroll = editor.paragraphLayoutCreationCount

                // Reinstallation is the host's explicit backend-generation seam.
                textSystem.installBackend(backend)
                editor.font = .systemFont(ofSize: 14)
                editor.layoutIfNeeded()
                editor.prepareVisibleParagraphLayouts()
                let afterBackendInvalidation = editor.paragraphLayoutCreationCount
                let cached = UInt64(editor.cachedParagraphLayoutCount)
                let paragraphIDsPreserved = editor.paragraphIDs == initialIDs
                guard paragraphIDsPreserved else {
                    throw BenchmarkFailure.semantic(
                        "local text edits replaced unaffected paragraph identities")
                }
                guard editor.stringValue.utf16.count == document.utf16.count + 3 else {
                    throw BenchmarkFailure.semantic("text edits produced the wrong document")
                }

                metrics = [
                    "paragraphs": UInt64(editor.paragraphIDs.count),
                    "initial_layout_creations": initialCreations,
                    "local_edit_layout_creations": afterEdits - initialCreations,
                    "width_invalidation_layout_creations": afterWidth - afterEdits,
                    "scroll_layout_creations": afterScroll - afterWidth,
                    "backend_invalidation_layout_creations":
                        afterBackendInvalidation - afterScroll,
                    "cached_paragraphs": cached,
                    "allocation_units": UInt64(editor.paragraphIDs.count) + cached + 2,
                    "copied_bytes": sourceBytes + 3,
                    "live_backend_layouts": UInt64(backend.liveLayoutCount),
                    "live_backend_layouts_after_teardown": 0,
                ]
                checksum.mix(UInt64(editor.paragraphIDs.count))
                checksum.mix(UInt64(editor.stringValue.utf8.count))
                checksum.mix(afterBackendInvalidation)
                consume(editor)
                retainedEditor = nil
            }
            metrics["live_backend_layouts_after_teardown"] =
                UInt64(backend.liveLayoutCount)
            return BenchmarkSample(
                metrics: metrics,
                semanticChecksum: checksum)
        })
}

@MainActor
private func collectionWorkload(itemCount: Int) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "collection",
        name: "virtualized-list-grid-\(itemCount)",
        inputSize: UInt64(itemCount),
        seed: 0x434f_4c4c_4543_544e,
        budgets: [
            .exact("list_rows", UInt64(itemCount)),
            .exact("grid_items", UInt64(itemCount)),
            .maximum("list_maximum_materialized", 32),
            // Six adaptive columns, the viewport rows, and one overscan row on
            // each edge cap the retained cell set well below one hundred.
            .maximum("grid_maximum_materialized", 80),
            .maximum("list_measurement_cache", 2_048),
            .maximum("grid_measurement_cache", 4_096),
            .maximum("allocation_units", 6_300),
        ],
        body: {
            let uiContext = UIContext(services: .inMemory())
            return try uiContext.construct {
                let items = (0..<itemCount).map {
                    CollectionItem(id: $0, revision: UInt64($0 & 3))
                }
                let snapshot = try CollectionSnapshot(items: items)

                var listMeasurements: UInt64 = 0
                let list = ListView()
                list.frame = Rect(x: 0, y: 0, width: 360, height: 480)
                list.overscan = 2
                list.makeRow = { View() }
                list.measureRow = { item, _ in
                    listMeasurements &+= 1
                    return 24 + Double(item.revision)
                }
                list.applySnapshot(snapshot)
                list.layoutIfNeeded()
                list.selectionMode = .multiple
                list.setSelectedItemIDs([
                    CollectionItemID(10), CollectionItemID(itemCount / 2),
                ])
                var listMaximum = list.materializedRowCount
                for step in 1...200 {
                    list.contentOffset = Point(x: 0, y: Double(step * 80))
                    list.layoutIfNeeded()
                    listMaximum = max(listMaximum, list.materializedRowCount)
                }

                var movedItems = items
                let moved = movedItems.remove(at: itemCount / 2)
                movedItems.insert(
                    CollectionItem(id: -1, revision: 0), at: 0)
                movedItems.append(moved)
                movedItems.remove(at: itemCount / 3)
                list.applySnapshot(try CollectionSnapshot(items: movedItems))
                list.layoutIfNeeded()
                guard list.selectedItemIDs.contains(CollectionItemID(itemCount / 2)) else {
                    throw BenchmarkFailure.semantic(
                        "list snapshot move did not preserve selection identity")
                }

                var gridMeasurements: UInt64 = 0
                let grid = VirtualGridView()
                grid.frame = Rect(x: 0, y: 0, width: 640, height: 480)
                grid.columns = .adaptive(minimumWidth: 96, maximumCount: 8)
                grid.cellSizing = .fixedHeight(72)
                grid.overscanRows = 1
                grid.makeCell = { View() }
                grid.measureCellHeight = { item, _ in
                    gridMeasurements &+= 1
                    return 64 + Double(item.revision)
                }
                grid.applySnapshot(snapshot)
                grid.layoutIfNeeded()
                var gridMaximum = grid.materializedCellCount
                for step in 1...200 {
                    grid.contentOffset = Point(x: 0, y: Double(step * 80))
                    grid.layoutIfNeeded()
                    gridMaximum = max(gridMaximum, grid.materializedCellCount)
                }
                grid.applySnapshot(try CollectionSnapshot(items: movedItems))
                grid.layoutIfNeeded()

                let allocationUnits = UInt64(
                    list.materializedRowCount + list.reusePoolCount
                        + list.measurementCacheEntryCount
                        + grid.materializedCellCount + grid.reusePoolCount
                        + grid.measurementCacheEntryCount)
                var checksum = UInt64(itemCount)
                checksum.mix(UInt64(list.selectedItemIDs.count))
                checksum.mix(UInt64(list.materializedRowCount))
                checksum.mix(UInt64(grid.materializedCellCount))
                checksum.mix(listMeasurements)
                checksum.mix(gridMeasurements)
                return BenchmarkSample(
                    metrics: [
                        "list_rows": UInt64(list.rowCount),
                        "grid_items": UInt64(grid.itemCount),
                        "list_measurements": listMeasurements,
                        "grid_measurements": gridMeasurements,
                        "list_maximum_materialized": UInt64(listMaximum),
                        "grid_maximum_materialized": UInt64(gridMaximum),
                        "list_materialized": UInt64(list.materializedRowCount),
                        "grid_materialized": UInt64(grid.materializedCellCount),
                        "list_reuse_pool": UInt64(list.reusePoolCount),
                        "grid_reuse_pool": UInt64(grid.reusePoolCount),
                        "list_measurement_cache":
                            UInt64(list.measurementCacheEntryCount),
                        "grid_measurement_cache":
                            UInt64(grid.measurementCacheEntryCount),
                        "allocation_units": allocationUnits,
                        "copied_bytes": UInt64((itemCount + movedItems.count) * 16),
                    ],
                    semanticChecksum: checksum)
            }
        })
}

@MainActor
private final class BenchmarkTextBackend: TextLayoutBackend {
    private var nextHandle: UInt64 = 1
    private var references: [TextLayoutHandle: Int] = [:]
    var generation: UInt64 = 1

    var liveLayoutCount: Int { references.count }

    func resolveFont(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor? {
        ResolvedFontDescriptor(
            familyName: descriptor.familyName ?? "Benchmark Sans",
            postScriptName: "BenchmarkSans-Regular",
            pointSize: descriptor.pointSize,
            weight: descriptor.weight,
            width: descriptor.width,
            slant: descriptor.slant)
    }

    func fontMetrics(for descriptor: FontDescriptor) -> FontMetrics? {
        let size = descriptor.pointSize
        return FontMetrics(
            ascender: size * 0.75,
            descender: size * 0.20,
            leading: size * 0.05,
            capHeight: size * 0.70,
            xHeight: size * 0.50)
    }

    func createLayout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        scale: Float
    ) -> TextBackendLayout? {
        let text = attributedText.string
        let handle = TextLayoutHandle(rawValue: nextHandle)
        nextHandle &+= 1
        precondition(nextHandle != 0)
        references[handle] = 1
        let width = min(
            containerWidth ?? .greatestFiniteMagnitude,
            Double(text.utf16.count) * 7 * Double(scale))
        let height = 16 * Double(scale)
        return TextBackendLayout(
            handle: handle,
            usedRect: Rect(x: 0, y: 0, width: max(0, width), height: height),
            lines: [TextLayoutLine(
                text: text,
                frame: Rect(x: 0, y: 0, width: max(0, width), height: height),
                baselineOffsetFromTop: 12 * Double(scale),
                sourceUTF16Range: 0..<text.utf16.count,
                lineNumber: 0,
                typographicAscent: 12 * Double(scale),
                typographicDescent: 4 * Double(scale))])
    }

    func retainLayout(_ handle: TextLayoutHandle) {
        guard let count = references[handle] else {
            preconditionFailure("retained unknown benchmark layout")
        }
        references[handle] = count + 1
    }

    func releaseLayout(_ handle: TextLayoutHandle) {
        guard let count = references[handle], count > 0 else {
            preconditionFailure("released unknown benchmark layout")
        }
        references[handle] = count == 1 ? nil : count - 1
    }

    func glyphPosition(
        at point: Point,
        in handle: TextLayoutHandle
    ) -> TextGlyphPosition? {
        references[handle] == nil
            ? nil
            : TextGlyphPosition(utf16Offset: max(0, Int(point.x / 7)))
    }

    func caretGeometry(
        atUTF16Offset offset: Int,
        affinity: TextAffinity,
        in handle: TextLayoutHandle
    ) -> TextCaretGeometry? {
        guard references[handle] != nil else { return nil }
        return TextCaretGeometry(
            rect: Rect(x: Double(max(0, offset)) * 7, y: 0, width: 1, height: 16),
            affinity: affinity)
    }

    func selectionRects(
        forUTF16Range range: Range<Int>,
        in handle: TextLayoutHandle
    ) -> [TextSelectionRect]? {
        guard references[handle] != nil else { return nil }
        return [TextSelectionRect(rect: Rect(
            x: Double(range.lowerBound) * 7,
            y: 0,
            width: Double(range.count) * 7,
            height: 16))]
    }
}
