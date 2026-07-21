import Foundation
import Glibc
import NucleusCompositorWaylandTestSupport
@testable import NucleusCompositorWaylandRuntime
import NucleusShellLoop
import NucleusShellWayland
import NucleusUI
import Testing
import WaylandClientC
import WaylandServerC
@testable import NucleusShellPasteboard

@MainActor
private func pumpDragFixtureSetup(
    _ runtime: WaylandRouterRuntime,
    clients: [ShellWaylandClient],
    cycles: Int = 32
) {
    for _ in 0..<cycles {
        for client in clients {
            _ = client.pumpNonBlocking()
        }
        runtime.dispatchClientsNonBlocking()
        for client in clients {
            _ = client.pumpNonBlocking()
        }
    }
}

@MainActor
@Suite(.serialized, .uiContext)
struct DragDropClientServerTests {
    @MainActor
    private final class Peer {
        let client: ShellWaylandClient
        let seat: ShellSeat
        let surface: OpaquePointer
        let surfaceID: UInt
        let serverSurfaceID: UInt32
        let window: Window
        let scene: WindowScene
        let root: View
        let drag: ShellWaylandDragDropAdapter
        let pasteboard: ShellWaylandPasteboardAdapter

        init(
            runtime: WaylandRouterRuntime,
            configure: (View) -> Void
        ) throws {
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
                throw DataTransferFailure.transport(
                    "server could not adopt fixture client")
            }
            client = try #require(ShellWaylandClient(
                connectedFileDescriptor: sockets[1]))
            pumpDragFixtureSetup(runtime, clients: [client])
            seat = try #require(ShellSeat(client: client))
            let priorSurfaceIDs = runtime.compositor.liveSurfaceIDs
            surface = try #require(client.createSurface())
            pumpDragFixtureSetup(runtime, clients: [client])
            serverSurfaceID = try #require(
                runtime.compositor.liveSurfaceIDs
                    .subtracting(priorSurfaceIDs)
                    .first)
            let fixtureSurfaceID = UInt(bitPattern: surface)
            surfaceID = fixtureSurfaceID

            root = View()
            root.frame = Rect(x: 0, y: 0, width: 240, height: 160)
            configure(root)
            window = Window(
                title: "Drag fixture",
                frame: Rect(x: 0, y: 0, width: 240, height: 160))
            window.setContentView(root)
            window.orderFront()
            let fixtureScene = WindowScene(inMemoryWindows: [window])
            scene = fixtureScene
            fixtureScene.makeKey(window)
            window.setSurfaceAssociation(WindowSurfaceAssociation(
                surfaceID: PresentationSurfaceID(
                    rawValue: UInt64(surfaceID))))

            guard let dragAdapter = ShellWaylandDragDropAdapter(
                client: client,
                seat: seat,
                destinationResolver: {
                    [weak fixtureScene] candidateSurface, location in
                    guard candidateSurface == fixtureSurfaceID,
                          let fixtureScene
                    else {
                        return nil
                    }
                    return (fixtureScene, location)
                })
            else {
                throw DataTransferFailure.transport(
                    "drag adapter could not bind")
            }
            drag = dragAdapter
            pasteboard = try #require(ShellWaylandPasteboardAdapter(
                client: client,
                seat: seat))
            pumpDragFixtureSetup(runtime, clients: [client])
        }

        isolated deinit {
            wl_surface_destroy(surface)
        }
    }

    @Test
    func productionEndpointsNegotiateTransferAndPreserveClipboard()
        async throws
    {
        let fixture = try #require(WaylandRouterTestFixture())
        defer { withExtendedLifetime(fixture) {} }
        let runtime = fixture.runtime
        runtime.seat.updateCapabilities(
            pointer: true,
            keyboard: false,
            touch: false)

        let sourceView = View()
        sourceView.frame = Rect(x: 10, y: 10, width: 60, height: 40)
        let source = try Peer(runtime: runtime) {
            $0.addSubview(sourceView)
        }
        var lifecycle: [String] = []
        var droppedPayload: DragPayload?
        let destinationView = View()
        destinationView.frame = Rect(
            x: 20,
            y: 20,
            width: 160,
            height: 100)
        destinationView.setDropDestination(DropDestinationConfiguration(
            acceptedContentTypes: ["text/plain"],
            proposal: { _ in
                DragDropProposal(
                    contentType: "text/plain",
                    operation: .move)
            },
            entered: { _ in lifecycle.append("enter") },
            updated: { _ in lifecycle.append("update") },
            exited: { _ in lifecycle.append("exit") },
            perform: { _, payload in
                lifecycle.append("drop")
                droppedPayload = payload
                return true
            }))
        let destination = try Peer(runtime: runtime) {
            $0.addSubview(destinationView)
        }
        pump(runtime, peers: [source, destination])

        try await source.pasteboard.writeString("clipboard-stays")
        pump(runtime, peers: [source, destination])

        authorizeDrag(from: source, runtime: runtime)
        pump(runtime, peers: [source, destination])
        #expect(sourceView.window === source.window)
        #expect(sourceView.window?.windowScene === source.scene)
        var sourceOutcomes: [DragCompletionOutcome] = []
        let preview = View()
        preview.frame = Rect(x: 0, y: 0, width: 12, height: 12)
        let configuration = DragSourceConfiguration(
            payloadProviders: [
                "text/plain": { Data("drag-payload".utf8) },
                "application/octet-stream": { Data([0xFF]) },
            ],
            allowedOperations: [.copy, .move],
            maximumPayloadBytes: 128,
            preview: preview,
            completion: { sourceOutcomes.append($0) })
        let sessionID = source.drag.startDrag(
            from: sourceView,
            source: configuration,
            originSurface: source.surface,
            at: Point(x: 30, y: 30))
        #expect(sessionID != nil)
        pump(runtime, peers: [source, destination])

        _ = runtime.dataDevice.dragMotion(
            surfaceID: UInt64(destination.serverSurfaceID),
            x: 60,
            y: 50,
            timeMsec: 10)
        pump(runtime, peers: [source, destination])
        #expect(lifecycle.first == "enter")
        #expect(lifecycle.contains("update"))

        #expect(runtime.dataDevice.dropActiveDrag())
        await driveTransfers(
            runtime,
            peers: [source, destination],
            until: { !sourceOutcomes.isEmpty })

        #expect(droppedPayload == DragPayload(
            contentType: "text/plain",
            data: Data("drag-payload".utf8)))
        #expect(lifecycle.last == "drop")
        #expect(sourceOutcomes == [.performed(.move)])
        #expect(preview.superview == nil)
        #expect(source.drag.activeTransferCount == 0)
        #expect(destination.drag.activeTransferCount == 0)

        #expect(try await readClipboard(
            destination: destination,
            peers: [source, destination],
            runtime: runtime) == "clipboard-stays")

        source.drag.shutdown()
        destination.drag.shutdown()
        source.pasteboard.shutdown()
        destination.pasteboard.shutdown()
    }

    @Test
    func cancellationAndSurfaceTeardownFinishEachSessionOnce() async throws {
        let fixture = try #require(WaylandRouterTestFixture())
        defer { withExtendedLifetime(fixture) {} }
        let runtime = fixture.runtime
        runtime.seat.updateCapabilities(
            pointer: true,
            keyboard: false,
            touch: false)
        let sourceView = View()
        sourceView.frame = Rect(x: 0, y: 0, width: 40, height: 40)
        let source = try Peer(runtime: runtime) {
            $0.addSubview(sourceView)
        }
        var exits = 0
        let destinationView = View()
        destinationView.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        destinationView.setDropDestination(DropDestinationConfiguration(
            acceptedContentTypes: ["text/plain"],
            proposal: { _ in
                DragDropProposal(
                    contentType: "text/plain",
                    operation: .copy)
            },
            exited: { _ in exits += 1 },
            perform: { _, _ in true }))
        let destination = try Peer(runtime: runtime) {
            $0.addSubview(destinationView)
        }
        pump(runtime, peers: [source, destination])

        #expect(source.drag.startDrag(
            from: sourceView,
            source: DragSourceConfiguration(payloadProviders: [
                "text/plain": { Data() }
            ]),
            originSurface: source.surface,
            at: .zero) == nil)

        authorizeDrag(from: source, runtime: runtime)
        pump(runtime, peers: [source, destination])
        var outcomes: [DragCompletionOutcome] = []
        #expect(source.drag.startDrag(
            from: sourceView,
            source: DragSourceConfiguration(
                payloadProviders: ["text/plain": { Data("x".utf8) }],
                completion: { outcomes.append($0) }),
            originSurface: source.surface,
            at: .zero) != nil)
        pump(runtime, peers: [source, destination])
        _ = runtime.dataDevice.dragMotion(
            surfaceID: UInt64(destination.serverSurfaceID),
            x: 20,
            y: 20,
            timeMsec: 20)
        pump(runtime, peers: [source, destination])

        runtime.dataDevice.cancelActiveDrag(notifySource: true)
        pump(runtime, peers: [source, destination])
        #expect(outcomes == [.cancelled])
        #expect(exits == 1)

        destination.drag.surfaceWillClose(destination.surfaceID)
        destination.drag.surfaceWillClose(destination.surfaceID)
        #expect(exits == 1)
        #expect(source.drag.activeTransferCount == 0)
        #expect(destination.drag.activeTransferCount == 0)

        source.drag.shutdown()
        source.drag.shutdown()
        destination.drag.shutdown()
        destination.drag.shutdown()
        source.pasteboard.shutdown()
        destination.pasteboard.shutdown()
    }

    private func authorizeDrag(
        from peer: Peer,
        runtime: WaylandRouterRuntime
    ) {
        guard let surface = runtime.compositor.surface(
                id: peer.serverSurfaceID),
              let resource = surface.resource,
              let client = wl_resource_get_client(resource)
        else {
            Issue.record("fixture surface did not reach compositor")
            return
        }
        _ = runtime.seat.pointerEnter(
            surface,
            surfaceX: 20,
            surfaceY: 20)
        _ = runtime.seat.pointerButton(
            clientKey: WlSeat.clientKey(client),
            surface: surface,
            timeMsec: 1,
            button: 0x110,
            state: UInt32(WL_POINTER_BUTTON_STATE_PRESSED.rawValue))
    }

    private func driveTransfers(
        _ runtime: WaylandRouterRuntime,
        peers: [Peer],
        until condition: () -> Bool
    ) async {
        for _ in 0..<1_024 where !condition() {
            pump(runtime, peers: peers, cycles: 1)
            for peer in peers {
                processReady(peer.drag)
            }
            await Task.yield()
        }
    }

    private func readClipboard(
        destination: Peer,
        peers: [Peer],
        runtime: WaylandRouterRuntime
    ) async throws -> String? {
        var result: Result<String?, any Error>?
        Task { @MainActor in
            do {
                result = .success(
                    try await destination.pasteboard.readString())
            } catch {
                result = .failure(error)
            }
        }
        for _ in 0..<1_024 where result == nil {
            pump(runtime, peers: peers, cycles: 1)
            for peer in peers {
                processReady(peer.pasteboard)
            }
            await Task.yield()
        }
        return try #require(result).get()
    }

    private func processReady(
        _ drag: ShellWaylandDragDropAdapter
    ) {
        for descriptor in drag.pollDescriptors {
            process(
                descriptor: descriptor,
                apply: drag.processPollResult)
        }
    }

    private func processReady(
        _ pasteboard: ShellWaylandPasteboardAdapter
    ) {
        for descriptor in pasteboard.pollDescriptors {
            process(
                descriptor: descriptor,
                apply: pasteboard.processPollResult)
        }
    }

    private func process(
        descriptor: ShellDataTransferPollDescriptor,
        apply: (
            _ token: UInt64,
            _ result: ShellPollResult,
            _ nowNanoseconds: UInt64
        ) -> Void
    ) {
        var polled = pollfd(
            fd: descriptor.fileDescriptor,
            events: descriptor.events,
            revents: 0)
        guard poll(&polled, 1, 0) > 0 else { return }
        apply(
            descriptor.token,
            ShellPollResult(revents: polled.revents),
            1)
    }

    private func pump(
        _ runtime: WaylandRouterRuntime,
        peers: [Peer],
        cycles: Int = 32
    ) {
        pump(runtime, clients: peers.map(\.client), cycles: cycles)
    }

    private func pump(
        _ runtime: WaylandRouterRuntime,
        clients: [ShellWaylandClient],
        cycles: Int = 32
    ) {
        for _ in 0..<cycles {
            for client in clients {
                _ = client.pumpNonBlocking()
            }
            runtime.dispatchClientsNonBlocking()
            for client in clients {
                _ = client.pumpNonBlocking()
            }
        }
    }
}
