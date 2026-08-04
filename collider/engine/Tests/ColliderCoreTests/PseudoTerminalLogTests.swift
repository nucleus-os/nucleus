import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test
func pseudoTerminalLogRetainsRawSlaveWrites() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let output = directory.appendingPathComponent("android-kmsg.log")
    let capture = try PseudoTerminalLog(
        output: FilePath(output.path))
    let slave = try FileDescriptor.open(
        FilePath(capture.slavePath),
        .writeOnly,
        options: [.closeOnExec])
    let message = "nucleus-kmsg\n"
    try slave.writeAll(Array(message.utf8))
    try slave.close()
    capture.stop()
    try capture.checkHealth()

    let contents = try String(contentsOf: output, encoding: .utf8)
    #expect(contents == message, "captured \(contents.debugDescription)")
}
