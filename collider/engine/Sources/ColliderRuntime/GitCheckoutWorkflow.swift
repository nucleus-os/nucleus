import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func syncGitCheckout(
        _ synchronization: GitCheckoutSync,
        stage: TaskID
    ) async throws {
        func git(
            _ arguments: [String],
            workingDirectory: FilePath
        ) async throws {
            let result = try await execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: synchronization.environment),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
        }
        let gitMetadata = synchronization.repository.appending(".git")
        if !FileManager.default.fileExists(atPath: gitMetadata.string) {
            if FileManager.default.fileExists(
                atPath: synchronization.repository.string)
            {
                throw RuntimeFailure.invalidOutput(
                    "refusing to replace non-git checkout "
                        + synchronization.repository.string)
            }
            try FileManager.default.createDirectory(
                atPath: synchronization.repository
                    .removingLastComponent().string,
                withIntermediateDirectories: true)
            try await git(
                [
                    "clone",
                    synchronization.remote,
                    synchronization.repository.string,
                ],
                workingDirectory:
                    synchronization.repository.removingLastComponent())
        }
        switch synchronization.revision {
        case .branch(let branch):
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "fetch", "origin", branch,
                ],
                workingDirectory: synchronization.repository)
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "reset", "--hard", "FETCH_HEAD",
                ],
                workingDirectory: synchronization.repository)
        case .tag(let tag):
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "fetch", "--tags", "origin", tag,
                ],
                workingDirectory: synchronization.repository)
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "reset", "--hard", tag,
                ],
                workingDirectory: synchronization.repository)
        case .commit(let commit):
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "fetch", "--depth", "1", "origin", commit,
                ],
                workingDirectory: synchronization.repository)
            try await git(
                [
                    "-C", synchronization.repository.string,
                    "reset", "--hard", commit,
                ],
                workingDirectory: synchronization.repository)
        }
        try await git(
            [
                "-C", synchronization.repository.string,
                "clean", "-fd",
            ],
            workingDirectory: synchronization.repository)
    }

    func validateGitCheckout(
        _ validation: GitCheckoutValidation,
        stage: TaskID
    ) async throws {
        func git(_ arguments: [String]) async throws -> CommandResult {
            try await execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: ["-C", validation.repository.string]
                        + arguments,
                    workingDirectory: validation.repository,
                    environment: validation.environment,
                    output: .captured(limit: 1_024 * 1_024)),
                stage: stage)
        }
        let revision = try await git(["rev-parse", "HEAD"])
        let actual = revision.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard revision.status == 0,
            actual == validation.expectedCommit
        else {
            throw RuntimeFailure.invalidOutput(
                "\(validation.repository) is at \(actual); expected "
                    + validation.expectedCommit)
        }
        if validation.requireClean {
            let status = try await git(["status", "--porcelain"])
            guard status.status == 0,
                status.standardOutput.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
            else {
                throw RuntimeFailure.invalidOutput(
                    "\(validation.repository) has local changes")
            }
        }
    }
}
