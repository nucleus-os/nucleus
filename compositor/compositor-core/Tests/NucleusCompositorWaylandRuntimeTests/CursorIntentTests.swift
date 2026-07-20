import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite struct CursorIntentTests {
    @Test func cursorPriorityIsResolvedWithoutStickyState() {
        #expect(resolveCursorIntent(
            resizeName: "ew-resize", clientOwnsCursor: true, shellControl: true)
            == .named("ew-resize"))
        #expect(resolveCursorIntent(
            resizeName: nil, clientOwnsCursor: true, shellControl: true) == .client)
        #expect(resolveCursorIntent(
            resizeName: nil, clientOwnsCursor: false, shellControl: true)
            == .named("pointer"))
        #expect(resolveCursorIntent(
            resizeName: nil, clientOwnsCursor: false, shellControl: false)
            == .named("default"))
    }

    @MainActor
    @Test func committedSurfaceOffsetMovesHotspotByInverseDelta() {
        PointerCursorSurface.bind(
            surfaceId: 42, hotspotX: 10, hotspotY: 20)
        PointerCursorSurface.applyCommittedOffset(
            surfaceID: 42, x: 3, y: -4)
        #expect(PointerCursorSurface.hotspotX == 7)
        #expect(PointerCursorSurface.hotspotY == 24)

        PointerCursorSurface.applyCommittedOffset(
            surfaceID: 99, x: 50, y: 50)
        #expect(PointerCursorSurface.hotspotX == 7)
        #expect(PointerCursorSurface.hotspotY == 24)
        PointerCursorSurface.clear()
    }
}
