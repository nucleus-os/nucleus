import Glibc
import NucleusCompositorWaylandTestSupport
import NucleusShellWayland
import NucleusUI
import Testing
import WaylandClientC
@testable import NucleusCompositorWaylandRuntime
@testable import NucleusShellInput

@MainActor
@Suite(.serialized, .uiContext)
struct ShellTextInputWireTests {
    @MainActor
    private final class Peer {
        let client: ShellWaylandClient
        let seat: ShellSeat
        let textInput: ShellTextInput
        let surface: OpaquePointer
        let serverSurfaceID: UInt32

        init(runtime: WaylandRouterRuntime) throws {
            var sockets = [Int32](repeating: -1, count: 2)
            try #require(socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue)
                    | O_NONBLOCK
                    | Int32(SOCK_CLOEXEC.rawValue),
                0,
                &sockets) == 0)
            guard runtime.attachClient(fileDescriptor: sockets[0]) else {
                close(sockets[0])
                close(sockets[1])
                throw TextInputWireFailure.serverAttach
            }
            client = try #require(ShellWaylandClient(
                connectedFileDescriptor: sockets[1]))
            Self.pump(runtime, client: client)
            seat = try #require(ShellSeat(client: client))
            textInput = try #require(ShellTextInput(
                client: client,
                seat: seat.protocolSeat))
            surface = try #require(client.createSurface())
            serverSurfaceID = wl_proxy_get_id(surface)
            Self.pump(runtime, client: client)
        }

        func shutdown(runtime: WaylandRouterRuntime) {
            textInput.close()
            wl_surface_destroy(surface)
            Self.pump(runtime, client: client)
        }

        static func pump(
            _ runtime: WaylandRouterRuntime,
            client: ShellWaylandClient,
            cycles: Int = 32
        ) {
            for _ in 0..<cycles {
                _ = client.pumpNonBlocking()
                runtime.dispatchClientsNonBlocking()
                _ = client.pumpNonBlocking()
            }
        }
    }

    private enum TextInputWireFailure: Error {
        case serverAttach
    }

    @Test func productionClientAndServerHonorTheCompleteSessionLifecycle()
        throws
    {
        let fixture = try #require(WaylandRouterTestFixture())
        defer { withExtendedLifetime(fixture) {} }
        let runtime = fixture.runtime
        runtime.seat.updateCapabilities(
            pointer: false,
            keyboard: true,
            touch: false)
        let peer = try Peer(runtime: runtime)
        defer { peer.shutdown(runtime: runtime) }

        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 260, height: 100)
        let field = TextField(string: "a😀e\u{301} אב")
        field.frame = Rect(x: 12, y: 14, width: 210, height: 28)
        root.addSubview(field)
        let secure = TextField(string: "swordfish", isSecure: true)
        secure.frame = Rect(x: 12, y: 54, width: 210, height: 28)
        root.addSubview(secure)
        let window = Window(
            title: "Text Input",
            frame: Rect(x: 100, y: 80, width: 260, height: 100))
        window.setContentView(root)
        window.setSurfaceAssociation(WindowSurfaceAssociation(
            surfaceID: PresentationSurfaceID(
                rawValue: UInt64(UInt(bitPattern: peer.surface))),
            transform: WindowSurfaceTransform(
                windowOriginInSurface: Point(x: 7.25, y: 3.5),
                surfaceOriginInOutput: Point(x: 100, y: 80),
                backingScaleFactor: BackingScaleFactor(1.5))))
        window.installTextInputAdapter(peer.textInput)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        #expect(window.makeFirstResponder(field))

        runtime.setFixtureKeyboardFocus(
            surfaceID: peer.serverSurfaceID)
        Peer.pump(runtime, client: peer.client)
        let initial = try #require(
            runtime.textInputManager.latestSnapshot)
        let initialContext = try #require(
            field.textInputSurroundingContext())
        #expect(initial.enabled)
        #expect(initial.focusedSurfaceID == peer.serverSurfaceID)
        #expect(initial.surroundingText == initialContext.text)
        #expect(initial.cursorByteOffset
            == Int32(initialContext.cursorByteOffset))
        #expect(initial.anchorByteOffset
            == Int32(initialContext.anchorByteOffset))
        #expect(initial.contentPurpose == 0)
        #expect(initial.contentHint & 0x3 == 0x3)
        #expect(initial.cursorRectangle == nil)

        wl_surface_commit(peer.surface)
        Peer.pump(runtime, client: peer.client)
        let appliedGeometry = try #require(
            runtime.textInputManager.latestSnapshot?.cursorRectangle)
        let candidate = try #require(field.textInputCandidateGeometry)
        let expectedGeometry = try #require(
            ShellTextInput.wireRectangle(candidate.rect))
        #expect(appliedGeometry == TextInputServerRectangle(
            x: expectedGeometry.x,
            y: expectedGeometry.y,
            width: expectedGeometry.width,
            height: expectedGeometry.height))

        func expectUpdatedCandidateGeometry(
            _ mutation: () -> Void
        ) throws {
            mutation()
            Peer.pump(runtime, client: peer.client)
            wl_surface_commit(peer.surface)
            Peer.pump(runtime, client: peer.client)
            let candidate = try #require(
                field.textInputCandidateGeometry)
            let expected = try #require(
                ShellTextInput.wireRectangle(candidate.rect))
            #expect(runtime.textInputManager.latestSnapshot?
                .cursorRectangle == TextInputServerRectangle(
                    x: expected.x,
                    y: expected.y,
                    width: expected.width,
                    height: expected.height))
        }
        try expectUpdatedCandidateGeometry {
            field.frame.origin.x += 4
        }
        try expectUpdatedCandidateGeometry {
            root.boundsOrigin = Point(x: 2, y: 1)
        }
        try expectUpdatedCandidateGeometry {
            root.transform = .translation(x: 3, y: 2)
        }
        try expectUpdatedCandidateGeometry {
            window.setSurfaceAssociation(WindowSurfaceAssociation(
                surfaceID: PresentationSurfaceID(
                    rawValue: UInt64(UInt(bitPattern: peer.surface))),
                transform: WindowSurfaceTransform(
                    windowOriginInSurface: Point(x: 9.75, y: 6.25),
                    surfaceOriginInOutput: Point(x: 140, y: 95),
                    backingScaleFactor: BackingScaleFactor(Double(2)))))
        }

        field.stringValue = "ab😀cd"
        let end = field.stringValue.utf16.count
        field.setSelectedRange(end..<end)
        Peer.pump(runtime, client: peer.client)
        let oldSessionSerial = try #require(
            runtime.textInputManager.latestSnapshot?.commitCount)
        var submitCount = 0
        field.onSubmit { _ in submitCount += 1 }
        #expect(runtime.textInputManager.send(
            TextInputServerEventBatch(
                preedit: (
                    text: "にほん",
                    cursorBegin: 3,
                    cursorEnd: 6),
                commit: "界",
                deleteBefore: 2,
                preeditHints: [
                    (start: 0, end: 3, hint: 5),
                    (start: 3, end: 6, hint: 1),
                ],
                language: "ja-JP",
                action: 1)))
        Peer.pump(runtime, client: peer.client)
        #expect(field.stringValue == "ab😀界にほん")
        #expect(field.markedRange == 5..<8)
        #expect(field.selectedRange == 6..<7)
        #expect(field.inputLanguage == "ja-JP")
        #expect(submitCount == 1)

        #expect(runtime.textInputManager.send(
            TextInputServerEventBatch(commit: "日本")))
        Peer.pump(runtime, client: peer.client)
        #expect(field.stringValue == "ab😀界日本")
        #expect(!field.hasMarkedText)

        let secureHistoryStart =
            runtime.textInputManager.snapshots.count
        #expect(window.makeFirstResponder(secure))
        Peer.pump(runtime, client: peer.client)
        let secureState = try #require(
            runtime.textInputManager.latestSnapshot)
        #expect(secureState.enabled)
        #expect(secureState.surroundingText == nil)
        #expect(secureState.cursorByteOffset == nil)
        #expect(secureState.anchorByteOffset == nil)
        #expect(secureState.contentPurpose == 8)
        #expect(secureState.contentHint & 0xc0 == 0xc0)
        #expect(!runtime.textInputManager.snapshots[
            secureHistoryStart...].contains {
                $0.surroundingText?.contains("swordfish") == true
            })

        #expect(runtime.textInputManager.send(
            TextInputServerEventBatch(
                commit: "stale",
                doneSerial: oldSessionSerial)))
        Peer.pump(runtime, client: peer.client)
        #expect(secure.stringValue == "swordfish")

        #expect(runtime.textInputManager.send(
            TextInputServerEventBatch(commit: "✓")))
        Peer.pump(runtime, client: peer.client)
        #expect(secure.stringValue == "swordfish✓")
        #expect(runtime.textInputManager.latestSnapshot?
            .surroundingText == nil)

        window.installTextInputAdapter(nil)
        Peer.pump(runtime, client: peer.client)
        #expect(runtime.textInputManager.latestSnapshot?.enabled == false)
        runtime.setFixtureKeyboardFocus(surfaceID: 0)
        Peer.pump(runtime, client: peer.client)
        #expect(runtime.textInputManager.latestSnapshot?
            .focusedSurfaceID == nil)

        try scene.disconnect()
        peer.textInput.close()
        Peer.pump(runtime, client: peer.client)
        #expect(runtime.textInputManager.liveResourceCount == 0)
    }
}
