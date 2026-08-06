import ColliderCore
import ColliderRuntime
import ColliderWorkspaceCommands
import Foundation
import NucleusAndroidRuntimeCore
import SystemPackage

extension RunningCommand: AndroidRuntimeRunningProcess {
    package func waitForExit() async throws -> AndroidRuntimeProcessResult {
        AndroidRuntimeProcessResult(status: try await wait().status)
    }
}

package final class ColliderAndroidKernelLog:
    AndroidRuntimeKernelLog, @unchecked Sendable
{
    private let log: PseudoTerminalLog

    package var slavePath: String { log.slavePath }

    package init(output: URL) throws {
        log = try PseudoTerminalLog(output: FilePath(output))
    }

    package func checkHealth() throws {
        try log.checkHealth()
    }

    package func stop() {
        log.stop()
    }
}

extension WorkspaceContext: AndroidRuntimeHost {
    package func execute(
        _ command: AndroidRuntimeCommand
    ) async throws -> String {
        try await run(
            command.executable,
            command.arguments,
            directory: command.directory,
            capture: command.capture,
            environmentOverrides: command.environmentOverrides,
            output: command.output.map(colliderOutput),
            timeoutSeconds: command.timeoutSeconds)
    }

    package func withRunningProcess<Value: Sendable>(
        _ command: AndroidRuntimeCommand,
        _ body: @escaping @Sendable (RunningCommand) async throws -> Value
    ) async throws -> Value {
        try await withRunningCommand(
            command.executable,
            command.arguments,
            directory: command.directory,
            environmentOverrides: command.environmentOverrides,
            output: colliderOutput(command.output ?? .inherited),
            body)
    }

    package func makeKernelLog(output: URL) throws -> ColliderAndroidKernelLog {
        try ColliderAndroidKernelLog(output: output)
    }

    package func addBinderDevice(
        control: URL,
        name: String
    ) throws -> AndroidRuntimeBinderDeviceNumber {
        let number = try BinderFS.addDevice(
            control: FilePath(control),
            name: name)
        return AndroidRuntimeBinderDeviceNumber(
            major: number.major,
            minor: number.minor)
    }

    private func colliderOutput(
        _ output: AndroidRuntimeCommandOutput
    ) -> CommandSpec.Output {
        switch output {
        case .inherited:
            .inherited
        case .file(let path):
            .file(FilePath(path))
        }
    }
}
