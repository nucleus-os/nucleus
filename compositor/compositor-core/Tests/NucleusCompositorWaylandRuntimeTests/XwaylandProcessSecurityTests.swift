import Foundation
import Glibc
import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite(.serialized)
struct XwaylandProcessSecurityTests {
    @Test func productionLaunchUsesAbsoluteExecutableAndMinimalContract() {
        let launch = XwaylandLaunchConfiguration(
            executablePath: "/usr/bin/Xwayland",
            displayNumber: 8)

        #expect(launch.arguments.first == "/usr/bin/Xwayland")
        #expect(launch.arguments.contains(":8"))
        #expect(!launch.arguments.contains("-core"))
        #expect(!launch.arguments.contains("-verbose"))
        #expect(!launch.arguments.contains("/usr/bin/env"))
        #expect(launch.environment == ["WAYLAND_SOCKET=3"])
        #expect(!launch.environment.contains {
            $0.hasPrefix("DISPLAY=") || $0.hasPrefix("WAYLAND_DEBUG=")
        })
    }

    @Test func runtimeDirectoryRejectsSymlinkOwnerAndUnsafeMode() throws {
        let fixture = try RuntimeDirectoryFixture()
        defer { fixture.remove() }

        let symlink = fixture.parent.appendingPathComponent("runtime-link")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: fixture.runtime)
        #expect(throws: XwaylandRuntimeDirectoryError.self) {
            try XwaylandRuntimeDirectory.open(runtimePath: symlink.path)
        }
        #expect(throws: XwaylandRuntimeDirectoryError.wrongOwner) {
            try XwaylandRuntimeDirectory.open(
                runtimePath: fixture.runtime.path,
                expectedUID: geteuid() &+ 1)
        }
        #expect(unsafe chmod(fixture.runtime.path, 0o755) == 0)
        #expect(throws: XwaylandRuntimeDirectoryError.unsafePermissions) {
            try XwaylandRuntimeDirectory.open(
                runtimePath: fixture.runtime.path)
        }
    }

    @Test func precreatedLogNameIsNeverModified() throws {
        let fixture = try RuntimeDirectoryFixture()
        defer { fixture.remove() }
        let runtime = try XwaylandRuntimeDirectory.open(
            runtimePath: fixture.runtime.path)
        let target = fixture.runtime
            .appendingPathComponent("nucleus")
            .appendingPathComponent("xwayland-fixed.log")
        try Data("sentinel".utf8).write(to: target)
        let sink = XwaylandTraceSink(
            directoryFD: runtime.fileDescriptor,
            nameGenerator: { "xwayland-fixed.log" })

        sink.consume([1, 2, 3])

        #expect(sink.failed)
        #expect(sink.droppedBytes == 3)
        #expect(try Data(contentsOf: target) == Data("sentinel".utf8))
    }

    @Test func concurrentTraceSinksCreateDistinctPrivateFiles() throws {
        let fixture = try RuntimeDirectoryFixture()
        defer { fixture.remove() }
        let runtime = try XwaylandRuntimeDirectory.open(
            runtimePath: fixture.runtime.path)
        let first = XwaylandTraceSink(
            directoryFD: runtime.fileDescriptor,
            nameGenerator: { "xwayland-first.log" })
        let second = XwaylandTraceSink(
            directoryFD: runtime.fileDescriptor,
            nameGenerator: { "xwayland-second.log" })

        first.consume([1])
        second.consume([2])

        let logDirectory = fixture.runtime.appendingPathComponent("nucleus")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: logDirectory.path).sorted()
        #expect(names == ["xwayland-first.log", "xwayland-second.log"])
        for name in names {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: logDirectory.appendingPathComponent(name).path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.uint16Value == 0o600)
        }
    }

    @Test func traceFloodRotatesAtThreeExactEightMiBFiles() throws {
        let fixture = try RuntimeDirectoryFixture()
        defer { fixture.remove() }
        let runtime = try XwaylandRuntimeDirectory.open(
            runtimePath: fixture.runtime.path)
        var sequence = 0
        let sink = XwaylandTraceSink(
            directoryFD: runtime.fileDescriptor,
            nameGenerator: {
                defer { sequence += 1 }
                return "xwayland-\(sequence).log"
            })
        let flood = [UInt8](
            repeating: 0x58,
            count: XwaylandTraceSink.byteLimit
                * XwaylandTraceSink.fileLimit + 17)

        sink.consume(flood)

        let logDirectory = fixture.runtime.appendingPathComponent("nucleus")
        let sizes = try FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.fileSizeKey])
            .map {
                try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            }
            .sorted()
        #expect(sizes == [
            17,
            XwaylandTraceSink.byteLimit,
            XwaylandTraceSink.byteLimit,
        ])
        #expect(!sink.failed)
        #expect(sink.droppedBytes == 0)
    }

    @Test func failedLaunchScopeClosesEveryOwnedDescriptor() throws {
        var firstPair: [Int32] = [-1, -1]
        var secondPair: [Int32] = [-1, -1]
        #expect(unsafe pipe2(&firstPair, O_CLOEXEC) == 0)
        #expect(unsafe pipe2(&secondPair, O_CLOEXEC) == 0)
        let closedDescriptors = firstPair + secondPair
        var retainedDescriptor: Int32 = -1

        do {
            let owned = XwaylandOwnedFileDescriptors()
            owned.insert(contentsOf: closedDescriptors)
            retainedDescriptor = fcntl(
                firstPair[0],
                F_DUPFD_CLOEXEC,
                64)
            #expect(retainedDescriptor >= 0)
            owned.insert(retainedDescriptor)
            owned.relinquish(retainedDescriptor)
        }

        for descriptor in closedDescriptors {
            errno = 0
            #expect(fcntl(descriptor, F_GETFD) == -1)
            #expect(errno == EBADF)
        }
        #expect(fcntl(retainedDescriptor, F_GETFD) >= 0)
        _ = close(retainedDescriptor)
    }

    @Test func childReapingNeverBlocksTheCallingExecutor() async throws {
        let child = fork()
        if child == 0 {
            while true {
                _ = pause()
            }
        }
        try #require(child > 0)

        let reaping = XwaylandChildReaper.terminate(
            child,
            gracefully: false)
        await reaping.value

        errno = 0
        #expect(waitpid(child, nil, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }
}

private struct RuntimeDirectoryFixture {
    let parent: URL
    let runtime: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        runtime = parent.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        guard unsafe chmod(runtime.path, 0o700) == 0 else {
            throw XwaylandRuntimeDirectoryError.openFailed(errno)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}
