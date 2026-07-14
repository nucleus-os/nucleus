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
}
