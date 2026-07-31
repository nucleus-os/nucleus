import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func validateSwiftSourceWorkspace(
        _ validation: SwiftSourceWorkspaceValidation,
        stage: TaskID
    ) async throws {
        let repositoryRoot = validation.workspaceRoot
            .removingLastComponent().removingLastComponent()
        let prefix = "swift-toolchain/source/"
        for repository in validation.repositories.sorted(by: {
            $0.string < $1.string
        }) {
            let relativePath = prefix + repository.string
            let submodule = try await swiftGit(
                ["submodule", "status", "--recursive", "--", relativePath],
                workingDirectory: repositoryRoot,
                environment: validation.environment,
                stage: stage)
            let entries = submodule.split(whereSeparator: \.isNewline)
            guard !entries.isEmpty,
                entries.allSatisfy({ line in
                    guard let state = line.first else { return false }
                    return state != "-" && state != "+" && state != "U"
                })
            else {
                throw RuntimeFailure.invalidOutput(
                    "Swift source submodule is not at its recorded gitlink: "
                        + relativePath)
            }
            let checkout = validation.workspaceRoot.appending(repository.components)
            let status = try await swiftGit(
                ["status", "--porcelain", "--untracked-files=all"],
                workingDirectory: checkout,
                environment: validation.environment,
                stage: stage)
            guard status.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "Swift source submodule has local changes: " + relativePath)
            }
        }
    }

    private func swiftGit(
        _ arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws -> String {
        let result = try await execute(
            CommandSpec(
                executable: .named("git"),
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
}
