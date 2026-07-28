import Foundation
import Glibc
import Testing
@testable import NucleusLinuxReactor

@Suite @MainActor struct LinuxFileWatcherTests {
    /// A watcher over a fresh directory, plus that directory's path.
    private func withWatchedFile(
        existing: Bool = true,
        _ body: @MainActor (LinuxFileWatcher, String, String) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "nucleus-watcher-tests-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        if existing {
            try Data("{}".utf8).write(to: file)
        }
        let watcher = try #require(LinuxFileWatcher(path: file.path))
        // The setup write may itself have queued an event; start from quiet.
        _ = watcher.drain()
        try body(watcher, file.path, directory.path)
    }

    // MARK: construction

    @Test func rejectsAPathWithNoParentDirectory() {
        #expect(LinuxFileWatcher(path: "config.json") == nil)
        #expect(LinuxFileWatcher(path: "") == nil)
        #expect(LinuxFileWatcher(path: "/") == nil)
    }

    @Test func rejectsADirectoryThatDoesNotExist() {
        // A user who has never written a configuration has nothing to reload;
        // synthesizing a watch on a missing tree would buy nothing.
        #expect(LinuxFileWatcher(
            path: "/nonexistent-nucleus-tree/nucleus/config.json") == nil)
    }

    @Test func watchesAFileThatDoesNotExistYet() throws {
        // The directory is what is watched, so a file created later is seen.
        try withWatchedFile(existing: false) { watcher, path, _ in
            try Data("{}".utf8).write(to: URL(filePath: path))
            #expect(watcher.drain().contentChanged)
        }
    }

    // MARK: change detection

    @Test func observesAnInPlaceWrite() throws {
        try withWatchedFile { watcher, path, _ in
            let handle = try FileHandle(forWritingTo: URL(filePath: path))
            try handle.write(contentsOf: Data("{\"a\":1}".utf8))
            try handle.close()
            let change = watcher.drain()
            #expect(change.contentChanged)
            #expect(!change.removed)
        }
    }

    @Test func observesAnAtomicRenameOverTheFile() throws {
        // The case that motivates watching the directory: most editors save by
        // writing a temporary file and renaming it into place, which replaces
        // the inode. A watch on the file itself would go permanently deaf here.
        try withWatchedFile { watcher, path, directory in
            let temporary = URL(filePath: directory).appending(path: ".tmp")
            try Data("{\"a\":2}".utf8).write(to: temporary)
            // rename(2) directly, because that is precisely what an editor
            // does — going through FileManager would test something else.
            #expect(unsafe rename(temporary.path, path) == 0)
            #expect(watcher.drain().contentChanged)
        }
    }

    @Test func reportsRemovalDistinctlyFromAContentChange() throws {
        try withWatchedFile { watcher, path, _ in
            try FileManager.default.removeItem(at: URL(filePath: path))
            let change = watcher.drain()
            #expect(change.removed)
            #expect(!change.contentChanged)
        }
    }

    @Test func aRecreatedFileReadsAsAContentChangeAgain() throws {
        try withWatchedFile { watcher, path, _ in
            try FileManager.default.removeItem(at: URL(filePath: path))
            #expect(watcher.drain().removed)
            try Data("{}".utf8).write(to: URL(filePath: path))
            let change = watcher.drain()
            #expect(change.contentChanged)
            #expect(!change.removed)
        }
    }

    // MARK: filtering and coalescing

    @Test func ignoresSiblingFilesInTheSameDirectory() throws {
        // The whole directory is watched, so unrelated traffic must not
        // trigger a reload — an editor's swap files sit right beside the
        // config and change constantly.
        try withWatchedFile { watcher, _, directory in
            let sibling = URL(filePath: directory).appending(path: "other.json")
            try Data("{}".utf8).write(to: sibling)
            #expect(watcher.drain().isEmpty)
        }
    }

    @Test func ignoresAFileWhoseNameMerelySharesAPrefix() throws {
        try withWatchedFile { watcher, _, directory in
            let sibling = URL(filePath: directory)
                .appending(path: "config.json.bak")
            try Data("{}".utf8).write(to: sibling)
            #expect(watcher.drain().isEmpty)
        }
    }

    @Test func coalescesABurstOfWritesIntoOneChange() throws {
        try withWatchedFile { watcher, path, _ in
            for value in 0..<5 {
                try Data("{\"a\":\(value)}".utf8)
                    .write(to: URL(filePath: path))
            }
            // One drain, one change — reload is idempotent, so reporting the
            // burst five times would only cost work.
            #expect(watcher.drain().contentChanged)
            #expect(watcher.drain().isEmpty)
        }
    }

    @Test func drainingWithNoActivityReportsNothing() throws {
        try withWatchedFile { watcher, _, _ in
            #expect(watcher.drain().isEmpty)
        }
    }

    // MARK: reactor contract

    @Test func exposesAReadableDescriptorAndNoTimeout() throws {
        try withWatchedFile { watcher, _, _ in
            #expect(watcher.fileDescriptor >= 0)
            #expect(watcher.pollEvents == Int16(POLLIN))
            // Purely descriptor-driven; a timeout wake would be wasted work.
            #expect(watcher.timeoutMicroseconds() == nil)
        }
    }

    @Test func processFiresTheCallbackOnlyWhenSomethingChanged() throws {
        try withWatchedFile { watcher, path, _ in
            var observed: [LinuxFileWatcher.Change] = []
            watcher.onChange = { observed.append($0) }

            #expect(watcher.process() == false)
            #expect(observed.isEmpty)

            try Data("{\"a\":1}".utf8).write(to: URL(filePath: path))
            #expect(watcher.process() == true)
            #expect(observed.count == 1)
            #expect(observed.first?.contentChanged == true)
        }
    }
}
