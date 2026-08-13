import Glibc
import NucleusRenderServerTestSupport
import NucleusUI
import NucleusUITestSupport
import NucleusWindowClientContracts
import NucleusWindowClientWayland
import Testing
import WaylandClient
import WaylandClientC
import WaylandClientDispatch
import WaylandProtocolTypes

@testable import NucleusCompositorWaylandRuntime
@testable import NucleusWindowClientInput

@MainActor
@Suite(.serialized, .uiContext)
struct NucleusDesktopTextInputWireTests {
    @Test func compositorDisconnectInvalidatesNegotiatedCapabilities() throws {
        let fixture = try #require(WaylandRouterTestFixture())
        let peer = try Peer(runtime: fixture.runtime)
        let compositor = try #require(
            peer.client.capability(for: .compositor))
        #expect(compositor.isValid)

        var observedDisconnect = false
        peer.client.onLifecycleEvent = { event in
            if case .compositorDisconnected = event {
                observedDisconnect = true
            }
        }
        peer.client.markCompositorDisconnected()

        #expect(!compositor.isValid)
        #expect(peer.client.capability(for: .compositor) == nil)
        #expect(observedDisconnect)
        peer.shutdown(runtime: fixture.runtime)
    }

    @Test func outputGlobalRemovalInvalidatesTheCapabilityAndTopology() throws {
        let fixture = try #require(WaylandRouterTestFixture())
        fixture.runtime.applyOutput(
            OutputInfo(
                outputId: 41,
                x: 0,
                y: 0,
                physicalWidthMm: 600,
                physicalHeightMm: 340,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshMhz: 60_000,
                scale: 1,
                name: "fixture-output",
                description: "Fixture Output",
                logicalWidth: 1920,
                logicalHeight: 1080,
                fractionalScale: 1))
        let peer = try Peer(runtime: fixture.runtime)
        let outputCapability = try #require(
            peer.client.capability(for: .output))
        #expect(outputCapability.isValid)
        #expect(peer.client.outputs.count == 1)

        var unavailableGeneration: UInt64?
        peer.client.onLifecycleEvent = { event in
            if case .capabilityUnavailable(.output, let generation) = event {
                unavailableGeneration = generation
            }
        }
        fixture.runtime.removeOutput(41)
        Peer.pump(fixture.runtime, client: peer.client)

        #expect(!outputCapability.isValid)
        #expect(peer.client.capability(for: .output) == nil)
        #expect(peer.client.outputs.isEmpty)
        #expect(unavailableGeneration == outputCapability.generation)
        peer.shutdown(runtime: fixture.runtime)
    }

    @Test func ordinaryWindowAndPopupRolesConfigureThroughPublicClientAPI()
        throws
    {
        let fixture = try #require(WaylandRouterTestFixture())
        let peer = try Peer(runtime: fixture.runtime)
        let windowCapability = try #require(
            peer.client.capability(for: .windowManagement))
        #expect(windowCapability.isValid)

        let window = try peer.client.createWindow(
            configuration: .init(
                title: "Fixture",
                applicationID: "org.nucleus.fixture"))
        var windowEvents: [NucleusDesktopWindowEvent] = []
        window.onEvent = { windowEvents.append($0) }
        Peer.pump(fixture.runtime, client: peer.client)
        #expect(
            windowEvents.contains { event in
                if case .configured = event { return true }
                return false
            })
        try window.setContentGeometry(width: 640, height: 480)
        Peer.pump(fixture.runtime, client: peer.client)

        let popup = try peer.client.createPopup(
            parent: window,
            configuration: .init(
                width: 160,
                height: 80,
                anchorX: 0,
                anchorY: 0,
                anchorWidth: 20,
                anchorHeight: 20))
        popup.close()
        window.close()
    }

    @Test func publicClientBuildsAStandardAtomicSurfaceTree() throws {
        let fixture = try #require(WaylandRouterTestFixture())
        let peer = try Peer(runtime: fixture.runtime)
        defer { peer.shutdown(runtime: fixture.runtime) }

        #expect(
            peer.client.capability(for: .subcompositor)?.isValid
                == true)
        #expect(
            peer.client.capability(for: .alphaModifier)?.isValid
                == true)

        let window = try peer.client.createWindow(
            configuration: .init(
                title: "Surface Tree",
                applicationID: "org.nucleus.surface-tree"))
        let first = try peer.client.createSubsurface(
            parent: window,
            configuration: .init(x: 8, y: 13))
        let second = try peer.client.createSubsurface(
            parent: window,
            configuration: .init(x: 21, y: 34))
        let grandchild = try peer.client.createSubsurface(
            parent: first,
            configuration: .init(x: 3, y: 5))
        defer {
            grandchild.close()
            second.close()
            first.close()
            window.close()
        }

        try first.setPosition(x: 55, y: 89)
        try second.placeBelow(first)
        try grandchild.setOpacity(0.5)
        try first.commit()
        try second.commit()
        try grandchild.commit()
        try window.setOpacity(0.75)
        try window.commit()
        Peer.pump(fixture.runtime, client: peer.client)

        #expect(
            peer.client.capability(for: .subcompositor)?.isValid
                == true)
        #expect(
            peer.client.capability(for: .alphaModifier)?.isValid
                == true)
    }

    @MainActor
    @discardableResult
    private static func pumpWaylandClient(
        _ client: NucleusDesktopConnection
    ) -> Int32 {
        guard let preparation = client.prepareRead() else { return -1 }
        let flushResult = client.flush()
        if flushResult < 0, errno != EAGAIN {
            preparation.read.cancel()
            return -1
        }
        var descriptor = pollfd(
            fd: client.fd,
            events: Int16(POLLIN),
            revents: 0)
        let pollResult = unsafe poll(&descriptor, 1, 0)
        let readable =
            pollResult > 0
            && descriptor.revents & Int16(POLLIN) != 0
        return preparation.read.complete(readable: readable)
    }

    @MainActor
    @discardableResult
    private static func pumpWaylandConnection(
        _ connection: WaylandConnection
    ) -> Int32 {
        guard let preparation = connection.prepareRead() else { return -1 }
        let flushResult = connection.flush()
        if flushResult < 0, errno != EAGAIN {
            preparation.read.cancel()
            return -1
        }
        var descriptor = pollfd(
            fd: connection.fd,
            events: Int16(POLLIN),
            revents: 0)
        let pollResult = unsafe poll(&descriptor, 1, 0)
        let readable =
            pollResult > 0
            && descriptor.revents & Int16(POLLIN) != 0
        return preparation.read.complete(readable: readable)
    }

    @MainActor
    @safe private final class Peer {
        let client: NucleusDesktopConnection
        let seat: NucleusDesktopSeat
        let textInput: NucleusDesktopTextInput
        let surface: WaylandProxy<WlSurfaceClient>
        let surfaceID: UInt
        let serverSurfaceID: UInt32

        init(runtime: WaylandRouterRuntime) throws {
            var sockets = [Int32](repeating: -1, count: 2)
            let socketResult = unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue)
                    | O_NONBLOCK
                    | Int32(SOCK_CLOEXEC.rawValue),
                0,
                &sockets)
            try #require(socketResult == 0)
            guard runtime.attachClient(fileDescriptor: sockets[0]) else {
                close(sockets[0])
                close(sockets[1])
                throw TextInputWireFailure.serverAttach
            }
            client = try #require(
                NucleusDesktopConnection(
                    connectedFileDescriptor: sockets[1]))
            Self.pump(runtime, client: client)
            seat = try #require(NucleusDesktopSeat(client: client))
            guard
                let createdTextInput = NucleusDesktopTextInput(
                    client: client,
                    seat: seat.protocolSeat)
            else { throw TextInputWireFailure.serverAttach }
            textInput = createdTextInput
            let createdSurface = try client.createSurface()
            surface = createdSurface
            surfaceID = createdSurface.identity
            serverSurfaceID = try unsafe createdSurface.withUnsafeNativeProxy {
                unsafe wl_proxy_get_id($0)
            }
            Self.pump(runtime, client: client)
        }

        func shutdown(runtime: WaylandRouterRuntime) {
            textInput.close()
            try? surface.destroy()
            Self.pump(runtime, client: client)
        }

        static func pump(
            _ runtime: WaylandRouterRuntime,
            client: NucleusDesktopConnection,
            cycles: Int = 32
        ) {
            for _ in 0..<cycles {
                _ = NucleusDesktopTextInputWireTests.pumpWaylandClient(client)
                runtime.dispatchClientsNonBlocking()
                _ = NucleusDesktopTextInputWireTests.pumpWaylandClient(client)
            }
        }
    }

    private enum TextInputWireFailure: Error {
        case serverAttach
    }

    @MainActor
    @safe private final class InputMethodPeer: ZwpInputMethodV2Events {
        let connection: WaylandConnection
        private let registry: WaylandRegistry
        private(set) var inputMethod: WaylandProxy<ZwpInputMethodV2Client>?
        private var duplicateInputMethod: WaylandProxy<ZwpInputMethodV2Client>?
        private(set) var activationCount = 0
        private(set) var deactivationCount = 0
        private(set) var doneCount: UInt32 = 0
        private(set) var surroundingText: String?
        private(set) var cursor: UInt32?
        private(set) var anchor: UInt32?
        private(set) var contentHint: UInt32 = 0
        private(set) var contentPurpose: UInt32 = 0
        private(set) var unavailable = false

        init(runtime: WaylandRouterRuntime) throws {
            var sockets = [Int32](repeating: -1, count: 2)
            let socketResult = unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue)
                    | O_NONBLOCK
                    | Int32(SOCK_CLOEXEC.rawValue),
                0,
                &sockets)
            try #require(socketResult == 0)
            guard runtime.attachClient(fileDescriptor: sockets[0]) else {
                close(sockets[0])
                close(sockets[1])
                throw TextInputWireFailure.serverAttach
            }
            connection = try #require(WaylandConnection(fd: sockets[1]))
            registry = try #require(
                WaylandRegistry(
                    connection,
                    wanting: [
                        DesiredGlobal<WlSeatClient>(),
                        DesiredGlobal<ZwpInputMethodManagerV2Client>(),
                    ]))
            Self.pump(runtime, connection: connection)
            let seat = try #require(registry.singleton(WlSeatClient.self))
            let manager = try #require(
                registry.singleton(ZwpInputMethodManagerV2Client.self))
            let inputMethod = try manager.getInputMethod(seat: seat)
            self.inputMethod = inputMethod
            try inputMethod.installListener(self)
            Self.pump(runtime, connection: connection)
        }

        func shutdown(runtime: WaylandRouterRuntime) {
            try? duplicateInputMethod?.destroy()
            duplicateInputMethod = nil
            try? inputMethod?.destroy()
            inputMethod = nil
            try? registry.singleton(ZwpInputMethodManagerV2Client.self)?.destroy()
            Self.pump(runtime, connection: connection)
        }

        func requestDuplicate(runtime: WaylandRouterRuntime) throws {
            let manager = try #require(
                registry.singleton(ZwpInputMethodManagerV2Client.self))
            let seat = try #require(registry.singleton(WlSeatClient.self))
            let duplicate = try manager.getInputMethod(seat: seat)
            duplicateInputMethod = duplicate
            try duplicate.installListener(self)
            Self.pump(runtime, connection: connection)
        }

        static func pump(
            _ runtime: WaylandRouterRuntime,
            app: NucleusDesktopConnection? = nil,
            connection: WaylandConnection,
            cycles: Int = 32
        ) {
            for _ in 0..<cycles {
                if let app {
                    _ = NucleusDesktopTextInputWireTests.pumpWaylandClient(app)
                }
                _ = NucleusDesktopTextInputWireTests.pumpWaylandConnection(connection)
                runtime.dispatchClientsNonBlocking()
                if let app {
                    _ = NucleusDesktopTextInputWireTests.pumpWaylandClient(app)
                }
                _ = NucleusDesktopTextInputWireTests.pumpWaylandConnection(connection)
            }
        }

        func activate(_ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>) {
            activationCount += 1
        }

        func deactivate(_ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>) {
            deactivationCount += 1
        }

        func surroundingText(
            _ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>,
            text: String,
            cursor: UInt32,
            anchor: UInt32
        ) {
            surroundingText = text
            self.cursor = cursor
            self.anchor = anchor
        }

        func textChangeCause(
            _ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>,
            cause: ZwpTextInputV3ChangeCause
        ) {}

        func contentType(
            _ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>,
            hint: ZwpTextInputV3ContentHint,
            purpose: ZwpTextInputV3ContentPurpose
        ) {
            contentHint = hint.rawValue
            contentPurpose = purpose.rawValue
        }

        func done(_ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>) {
            doneCount &+= 1
        }

        func unavailable(_ proxy: WaylandBorrowedProxy<ZwpInputMethodV2Client>) {
            unavailable = true
        }
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
        let inputMethodPeer = try InputMethodPeer(runtime: runtime)
        defer { inputMethodPeer.shutdown(runtime: runtime) }

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
        window.setSurfaceAssociation(
            WindowSurfaceAssociation(
                surfaceID: PresentationSurfaceID(
                    rawValue: UInt64(peer.surfaceID)),
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
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        let initial = try #require(
            runtime.textInputSeat.latestSnapshot)
        let initialContext = try #require(
            field.textInputSurroundingContext())
        #expect(initial.enabled)
        #expect(initial.focusedSurfaceID == peer.serverSurfaceID)
        #expect(initial.surroundingText == initialContext.text)
        #expect(
            initial.cursorByteOffset
                == Int32(initialContext.cursorByteOffset))
        #expect(
            initial.anchorByteOffset
                == Int32(initialContext.anchorByteOffset))
        #expect(initial.contentPurpose == 0)
        #expect(initial.contentHint & 0x3 == 0x3)
        #expect(initial.cursorRectangle == nil)
        #expect(inputMethodPeer.activationCount == 1)
        #expect(inputMethodPeer.deactivationCount == 0)
        #expect(inputMethodPeer.surroundingText == initialContext.text)
        #expect(inputMethodPeer.cursor == UInt32(initialContext.cursorByteOffset))
        #expect(inputMethodPeer.anchor == UInt32(initialContext.anchorByteOffset))
        #expect(inputMethodPeer.contentPurpose == 0)
        #expect(inputMethodPeer.contentHint & 0x3 == 0x3)
        try inputMethodPeer.requestDuplicate(runtime: runtime)
        #expect(inputMethodPeer.unavailable)

        let inputMethod = try #require(inputMethodPeer.inputMethod)
        let firstInputMethodSerial = inputMethodPeer.doneCount
        try inputMethod.commitString(text: "界")
        try inputMethod.setPreeditString(
            text: "かな", cursor_begin: 3, cursor_end: 6)
        try inputMethod.commit(serial: firstInputMethodSerial)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        #expect(field.stringValue.contains("界かな"))
        #expect(field.hasMarkedText)
        let stateAfterInputMethodCommit = field.stringValue

        try inputMethod.commitString(text: "stale")
        try inputMethod.commit(serial: firstInputMethodSerial)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        #expect(field.stringValue == stateAfterInputMethodCommit)

        try peer.surface.commit()
        Peer.pump(runtime, client: peer.client)
        let appliedGeometry = try #require(
            runtime.textInputSeat.latestSnapshot?.cursorRectangle)
        let candidate = try #require(field.textInputCandidateGeometry)
        let expectedGeometry = try #require(
            NucleusDesktopTextInput.wireRectangle(candidate.rect))
        #expect(
            appliedGeometry
                == TextInputServerRectangle(
                    x: expectedGeometry.x,
                    y: expectedGeometry.y,
                    width: expectedGeometry.width,
                    height: expectedGeometry.height))

        func expectUpdatedCandidateGeometry(
            _ mutation: () -> Void
        ) throws {
            mutation()
            Peer.pump(runtime, client: peer.client)
            try peer.surface.commit()
            Peer.pump(runtime, client: peer.client)
            let candidate = try #require(
                field.textInputCandidateGeometry)
            let expected = try #require(
                NucleusDesktopTextInput.wireRectangle(candidate.rect))
            #expect(
                runtime.textInputSeat.latestSnapshot?
                    .cursorRectangle
                    == TextInputServerRectangle(
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
            window.setSurfaceAssociation(
                WindowSurfaceAssociation(
                    surfaceID: PresentationSurfaceID(
                        rawValue: UInt64(peer.surfaceID)),
                    transform: WindowSurfaceTransform(
                        windowOriginInSurface: Point(x: 9.75, y: 6.25),
                        surfaceOriginInOutput: Point(x: 140, y: 95),
                        backingScaleFactor: BackingScaleFactor(Double(2)))))
        }

        field.stringValue = "ab😀cd"
        let end = field.stringValue.utf16.count
        field.setSelectedRange(end..<end)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)

        let deleteSerial = inputMethodPeer.doneCount
        try inputMethod.deleteSurroundingText(
            before_length: 2, after_length: 0)
        try inputMethod.commitString(text: "界")
        try inputMethod.commit(serial: deleteSerial)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        #expect(field.stringValue == "ab😀界")

        let beforeInvalidPreedit = field.stringValue
        let invalidPreeditSerial = inputMethodPeer.doneCount
        try inputMethod.setPreeditString(
            text: "😀", cursor_begin: 1, cursor_end: 1)
        try inputMethod.commit(serial: invalidPreeditSerial)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        #expect(field.stringValue == beforeInvalidPreedit)

        field.stringValue = "ab😀cd"
        field.setSelectedRange(end..<end)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        let oldSessionSerial = try #require(
            runtime.textInputSeat.latestSnapshot?.commitCount)
        var submitCount = 0
        field.onSubmit { _ in submitCount += 1 }
        #expect(
            runtime.textInputSeat.send(
                TextInputServerEventBatch(
                    preedit: (
                        text: "にほん",
                        cursorBegin: 3,
                        cursorEnd: 6
                    ),
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

        #expect(
            runtime.textInputSeat.send(
                TextInputServerEventBatch(commit: "日本")))
        Peer.pump(runtime, client: peer.client)
        #expect(field.stringValue == "ab😀界日本")
        #expect(!field.hasMarkedText)

        let secureHistoryStart =
            runtime.textInputSeat.snapshots.count
        #expect(window.makeFirstResponder(secure))
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        let secureState = try #require(
            runtime.textInputSeat.latestSnapshot)
        #expect(secureState.enabled)
        #expect(secureState.surroundingText == nil)
        #expect(secureState.cursorByteOffset == nil)
        #expect(secureState.anchorByteOffset == nil)
        #expect(secureState.contentPurpose == 8)
        #expect(secureState.contentHint & 0xc0 == 0xc0)
        #expect(inputMethodPeer.activationCount == 2)
        #expect(inputMethodPeer.deactivationCount == 1)
        #expect(inputMethodPeer.surroundingText != "swordfish")
        #expect(inputMethodPeer.contentPurpose == 8)
        #expect(
            !runtime.textInputSeat.snapshots[
                secureHistoryStart...
            ].contains {
                $0.surroundingText?.contains("swordfish") == true
            })

        #expect(
            runtime.textInputSeat.send(
                TextInputServerEventBatch(
                    commit: "stale",
                    doneSerial: oldSessionSerial)))
        Peer.pump(runtime, client: peer.client)
        #expect(secure.stringValue == "swordfish")

        #expect(
            runtime.textInputSeat.send(
                TextInputServerEventBatch(commit: "✓")))
        Peer.pump(runtime, client: peer.client)
        #expect(secure.stringValue == "swordfish✓")
        #expect(
            runtime.textInputSeat.latestSnapshot?
                .surroundingText == nil)

        window.installTextInputAdapter(nil)
        InputMethodPeer.pump(
            runtime,
            app: peer.client,
            connection: inputMethodPeer.connection)
        #expect(runtime.textInputSeat.latestSnapshot?.enabled == false)
        #expect(inputMethodPeer.deactivationCount == 2)
        runtime.setFixtureKeyboardFocus(surfaceID: 0)
        Peer.pump(runtime, client: peer.client)
        #expect(
            runtime.textInputSeat.latestSnapshot?
                .focusedSurfaceID == nil)

        inputMethodPeer.shutdown(runtime: runtime)
        #expect(runtime.textInputSeat.inputMethod == nil)

        try scene.disconnect()
        peer.textInput.close()
        Peer.pump(runtime, client: peer.client)
        #expect(runtime.textInputSeat.liveResourceCount == 0)
    }
}
