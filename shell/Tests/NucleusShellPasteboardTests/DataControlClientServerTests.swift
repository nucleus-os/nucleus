import Glibc
import NucleusCompositorWaylandRuntime
import NucleusShellLoop
import NucleusShellWayland
import NucleusUI
import Testing
@testable import NucleusShellPasteboard

@MainActor
@Suite(.serialized)
struct DataControlClientServerTests {
    @MainActor
    private final class Peer {
        let client: ShellWaylandClient
        let seat: ShellSeat
        var pasteboard: ShellWaylandPasteboardAdapter

        init(
            runtime: WaylandRouterRuntime,
            limits: ShellDataTransferLimits = ShellDataTransferLimits()
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
                throw PasteboardFailure.transport(
                    "server could not adopt fixture client")
            }
            client = try #require(ShellWaylandClient(
                connectedFileDescriptor: sockets[1]))
            for _ in 0..<16 {
                _ = client.pumpNonBlocking()
                runtime.dispatchClientsNonBlocking()
            }
            seat = try #require(ShellSeat(client: client))
            pasteboard = try #require(ShellWaylandPasteboardAdapter(
                client: client,
                seat: seat,
                limits: limits))
        }

        func rebindPasteboard(
            limits: ShellDataTransferLimits = ShellDataTransferLimits()
        ) throws {
            pasteboard.shutdown()
            pasteboard = try #require(ShellWaylandPasteboardAdapter(
                client: client,
                seat: seat,
                limits: limits))
        }
    }

    @Test func productionEndpointsCopyReplaceClearAndReleaseResources() async throws {
        let runtime = try #require(makeTestWaylandRouterRuntime())
        let source = try Peer(runtime: runtime)
        let destination = try Peer(runtime: runtime)
        pump(runtime, peers: [source, destination])

        let first = String(repeating: "clipboard-", count: 16 * 1024)
        try await source.pasteboard.writeString(first)
        pump(runtime, peers: [source, destination])
        let receivedFirst = try await transferRead(
            from: destination,
            serving: [source, destination],
            runtime: runtime)
        #expect(receivedFirst == first)

        try await source.pasteboard.writeString("replacement")
        pump(runtime, peers: [source, destination])
        #expect(source.pasteboard.resourceCounts.sources == 1)
        let receivedReplacement = try await transferRead(
            from: destination,
            serving: [source, destination],
            runtime: runtime)
        #expect(receivedReplacement == "replacement")

        try await source.pasteboard.clear()
        pump(runtime, peers: [source, destination])
        #expect(try await destination.pasteboard.readString() == nil)
        #expect(source.pasteboard.resourceCounts.sources == 0)
        #expect(destination.pasteboard.resourceCounts.offers == 0)

        source.pasteboard.shutdown()
        destination.pasteboard.shutdown()
        #expect(source.pasteboard.resourceCounts
            == ShellPasteboardResourceCounts(
                offers: 0, sources: 0, devices: 0, transfers: 0))
        #expect(destination.pasteboard.resourceCounts
            == ShellPasteboardResourceCounts(
                offers: 0, sources: 0, devices: 0, transfers: 0))
    }

    @Test func productionEndpointsRejectOversizedTransferAndRecover() async throws {
        let runtime = try #require(makeTestWaylandRouterRuntime())
        let source = try Peer(runtime: runtime)
        let destination = try Peer(
            runtime: runtime,
            limits: ShellDataTransferLimits(maximumBytes: 32))
        pump(runtime, peers: [source, destination])

        try await source.pasteboard.writeString(String(repeating: "x", count: 64))
        pump(runtime, peers: [source, destination])
        do {
            _ = try await transferRead(
                from: destination,
                serving: [source, destination],
                runtime: runtime)
            Issue.record("oversized production transfer unexpectedly succeeded")
        } catch let failure {
            #expect(failure == .transport(
                "transfer exceeded 32 byte limit"))
        }
        #expect(destination.pasteboard.activeTransferCount == 0)

        try await source.pasteboard.writeString("small")
        pump(runtime, peers: [source, destination])
        #expect(try await transferRead(
            from: destination,
            serving: [source, destination],
            runtime: runtime) == "small")

        source.pasteboard.shutdown()
        destination.pasteboard.shutdown()
    }

    @Test func unsupportedMIMESetDoesNotCreateATransfer() async throws {
        let runtime = try #require(makeTestWaylandRouterRuntime())
        let source = try Peer(runtime: runtime)
        let destination = try Peer(runtime: runtime)
        pump(runtime, peers: [source, destination])

        try source.pasteboard.publish(
            payload: Array("opaque".utf8),
            mimeTypes: ["application/octet-stream"])
        pump(runtime, peers: [source, destination])

        #expect(try await destination.pasteboard.readString() == nil)
        #expect(destination.pasteboard.activeTransferCount == 0)

        try await source.pasteboard.writeString("text")
        pump(runtime, peers: [source, destination])
        #expect(try await transferRead(
            from: destination,
            serving: [source, destination],
            runtime: runtime) == "text")

        source.pasteboard.shutdown()
        destination.pasteboard.shutdown()
    }

    @Test func deviceRebindAndClientReconnectReprojectLiveSelection() async throws {
        let runtime = try #require(makeTestWaylandRouterRuntime())
        var source: Peer? = try Peer(runtime: runtime)
        let destination = try Peer(runtime: runtime)
        do {
            let initialSource = try #require(source)
            pump(runtime, peers: [initialSource, destination])

            try await initialSource.pasteboard.writeString("before-rebind")
            pump(runtime, peers: [initialSource, destination])
            try destination.rebindPasteboard()
            pump(runtime, peers: [initialSource, destination])
            #expect(try await transferRead(
                from: destination,
                serving: [initialSource, destination],
                runtime: runtime) == "before-rebind")

            initialSource.pasteboard.shutdown()
        }
        source = nil
        pump(runtime, peers: [destination])
        #expect(try await destination.pasteboard.readString() == nil)

        let reconnectedSource = try Peer(runtime: runtime)
        pump(runtime, peers: [reconnectedSource, destination])
        try await reconnectedSource.pasteboard.writeString("after-reconnect")
        pump(runtime, peers: [reconnectedSource, destination])
        #expect(try await transferRead(
            from: destination,
            serving: [reconnectedSource, destination],
            runtime: runtime) == "after-reconnect")

        reconnectedSource.pasteboard.shutdown()
        destination.pasteboard.shutdown()
    }

    private func transferRead(
        from destination: Peer,
        serving peers: [Peer],
        runtime: WaylandRouterRuntime
    ) async throws(PasteboardFailure) -> String? {
        var result: Result<String?, PasteboardFailure>?
        Task { @MainActor in
            result = await readResult(from: destination.pasteboard)
        }
        await Task.yield()

        for _ in 0..<1_024 where result == nil {
            pump(runtime, peers: peers, cycles: 1)
            for peer in peers {
                processReadyTransfers(peer.pasteboard)
            }
            await Task.yield()
        }
        guard let result else {
            throw .transport("fixture transfer did not complete")
        }
        return try result.get()
    }

    private func readResult(
        from pasteboard: ShellWaylandPasteboardAdapter
    ) async -> Result<String?, PasteboardFailure> {
        do {
            return .success(try await pasteboard.readString())
        } catch let failure {
            return .failure(failure)
        }
    }

    private func processReadyTransfers(
        _ pasteboard: ShellWaylandPasteboardAdapter
    ) {
        for descriptor in pasteboard.pollDescriptors {
            var pollDescriptor = pollfd(
                fd: descriptor.fileDescriptor,
                events: descriptor.events,
                revents: 0)
            let ready = poll(&pollDescriptor, 1, 0)
            guard ready > 0 else { continue }
            pasteboard.processPollResult(
                token: descriptor.token,
                result: ShellPollResult(
                    revents: pollDescriptor.revents),
                nowNanoseconds: 1)
        }
    }

    private func pump(
        _ runtime: WaylandRouterRuntime,
        peers: [Peer],
        cycles: Int = 32
    ) {
        for _ in 0..<cycles {
            for peer in peers {
                _ = peer.client.pumpNonBlocking()
            }
            runtime.dispatchClientsNonBlocking()
            for peer in peers {
                _ = peer.client.pumpNonBlocking()
            }
        }
    }
}
