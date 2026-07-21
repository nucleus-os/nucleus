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
        let graph = WaylandTestGraph()
        let cursor = graph.host.pointerCursorSurface
        cursor.bind(
            surfaceId: 42, hotspotX: 10, hotspotY: 20)
        cursor.applyCommittedOffset(
            surfaceID: 42, x: 3, y: -4)
        #expect(cursor.hotspotX == 7)
        #expect(cursor.hotspotY == 24)

        cursor.applyCommittedOffset(
            surfaceID: 99, x: 50, y: 50)
        #expect(cursor.hotspotX == 7)
        #expect(cursor.hotspotY == 24)
        cursor.clear()
    }
}
