import Foundation
import Glibc
import NucleusLinuxSession

private enum FixtureFailure: Error {
    case missingDirectory
    case malformedDescriptor
}

private func writeText(_ value: String, to path: String) throws {
    try Data(value.utf8).write(
        to: URL(fileURLWithPath: path),
        options: .atomic)
}

private func waitForFile(_ path: String) {
    while access(path, F_OK) != 0 { usleep(10_000) }
}

private func descriptor(
    following argument: String,
    in arguments: [String]
) throws -> Int32 {
    guard let index = arguments.firstIndex(of: argument),
          arguments.indices.contains(index + 1),
          let value = Int32(arguments[index + 1])
    else { throw FixtureFailure.malformedDescriptor }
    return value
}

private func run() throws -> Int32 {
    let role = try SessionProcessRole.inherited()
    let configuration = try SessionConfiguration.inherited()
    guard let directoryValue = getenv("NUCLEUS_SESSION_FIXTURE_DIRECTORY")
    else { throw FixtureFailure.missingDirectory }
    let directory = String(cString: directoryValue)
    let roleName = role == .compositor ? "compositor" : "shell"
    try writeText(
        configuration.hexEncoded,
        to: directory + "/\(roleName)-configuration")
    try writeText(
        String(getpid()),
        to: directory + "/\(roleName)-pid")

    let modeName = "NUCLEUS_SESSION_FIXTURE_"
        + roleName.uppercased() + "_MODE"
    let mode = getenv(modeName).map { String(cString: $0) }
        ?? "ready-wait"
    if mode == "wait-before-ready" {
        waitForFile(directory + "/release-\(roleName)")
    }
    if mode == "exit-before-ready" { return 71 }
    if mode == "missing-readiness" { return 0 }
    if mode == "malformed-readiness" {
        let readinessDescriptor = try descriptor(
            following: SessionReadinessReporter.descriptorArgument,
            in: CommandLine.arguments)
        var bytes = [UInt8](repeating: 0xa5, count: 12)
        _ = write(readinessDescriptor, &bytes, bytes.count)
        _ = close(readinessDescriptor)
        return 0
    }

    let reporter = try SessionReadinessReporter.inherited(role: role)
    try reporter?.report(
        role == .compositor ? .compositorReady : .shellReady)
    try writeText("ready", to: directory + "/\(roleName)-ready")

    if mode == "exit-after-peer-ready" {
        let peer = role == .compositor ? "shell" : "compositor"
        waitForFile(directory + "/\(peer)-ready")
        return role == .compositor ? 72 : 73
    }
    if mode == "exit-after-ready" {
        return role == .compositor ? 72 : 73
    }
    while true { pause() }
}

do {
    exit(try run())
} catch {
    let line = "nucleus-session-fixture: \(error)\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    exit(70)
}
