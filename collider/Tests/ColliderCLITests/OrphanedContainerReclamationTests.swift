import ColliderRuntime
import Foundation
import Synchronization
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

private func container(
    _ name: String,
    infrastructure: Bool = false
) -> OCIContainerState {
    OCIContainerState(
        name: name,
        imageReference: "fixture:latest",
        running: true,
        infrastructure: infrastructure)
}

private final class OutputCapture: Sendable {
    private let data = Mutex(Data())
    func write(_ bytes: Data) { data.withLock { $0.append(bytes) } }
    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}

private final class Deletions: Sendable {
    private let names = Mutex<[String]>([])
    func record(_ name: String) { names.withLock { $0.append(name) } }
    var values: [String] { names.withLock { $0 } }
}

/// A container that exists while this run holds the machine's single execution
/// admission cannot belong to a live run, because there is no other live run.
/// It belongs to one that was cancelled, whose asynchronous container cleanup
/// never got its turn before the process was killed. Reclaiming it here is
/// what a signal-time cleanup cannot promise, since nothing survives SIGKILL.
@Test func admissionReclaimsContainersLeftByRunsThatAreOver() async {
    let deleted = Deletions()
    await reclaimOrphanedContainers(
        listing: {
            [
                container("chromium-build-b2235d0a-d4c"),
                container("nucleus-swiftpm-overlay-2fd07a36-971"),
            ]
        },
        deleting: { deleted.record($0) },
        console: CommandConsole(
            progress: .never,
            standardErrorIsTerminal: false,
            standardOutput: { _ in },
            standardError: { _ in }))

    #expect(
        deleted.values == [
            "chromium-build-b2235d0a-d4c",
            "nucleus-swiftpm-overlay-2fd07a36-971",
        ])
}

/// Infrastructure containers belong to the runtime rather than to any run, so
/// the admission says nothing about them and reclaiming one would take out the
/// service the run is about to use.
@Test func reclamationLeavesTheRuntimesOwnContainersAlone() async {
    let deleted = Deletions()
    await reclaimOrphanedContainers(
        listing: {
            [
                container("buildkit", infrastructure: true),
                container("chromium-build-1519ed74-a15"),
            ]
        },
        deleting: { deleted.record($0) },
        console: CommandConsole(
            progress: .never,
            standardErrorIsTerminal: false,
            standardOutput: { _ in },
            standardError: { _ in }))

    #expect(deleted.values == ["chromium-build-1519ed74-a15"])
}

/// Reclamation is opportunistic. A command that never runs a container is not
/// worth failing over a container service that cannot be reached, and one that
/// does will fail on its own with this diagnostic already above it.
@Test func reclamationReportsFailuresWithoutFailingTheCommand() async {
    struct Unreachable: Error {}
    let capture = OutputCapture()
    let deleted = Deletions()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: capture.write)

    await reclaimOrphanedContainers(
        listing: { [container("stuck"), container("fine")] },
        deleting: { name in
            guard name != "stuck" else { throw Unreachable() }
            deleted.record(name)
        },
        console: console)

    #expect(capture.text.contains("could not reclaim container stuck"))
    // One failure does not abandon the rest.
    #expect(deleted.values == ["fine"])

    let listingCapture = OutputCapture()
    await reclaimOrphanedContainers(
        listing: { throw Unreachable() },
        deleting: { _ in Issue.record("must not delete without a listing") },
        console: CommandConsole(
            progress: .always,
            standardErrorIsTerminal: false,
            standardOutput: { _ in },
            standardError: listingCapture.write))
    #expect(listingCapture.text.contains("could not inspect containers"))
}
