import Foundation

func makeTestRuntimeDirectory() throws -> URL {
    let directory = URL(
        fileURLWithPath: "/tmp/nsp-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false)
    return directory
}
