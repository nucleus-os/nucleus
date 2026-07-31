import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareChromiumDepotTools(
        _ preparation: ChromiumDepotToolsPreparation,
        stage: TaskID
    ) async throws {
        try await prepareManagedSource(
            repository: preparation.repository,
            remote: preparation.remote,
            reference: .commit(preparation.commit),
            partialClone: false,
            environment: preparation.environment,
            stage: stage)
    }

    private func prepareManagedSource(
        repository: FilePath,
        remote: String,
        reference: ManagedSourceReference,
        partialClone: Bool,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        func git(_ arguments: [String], workingDirectory: FilePath) async throws {
            let result = try await execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
        }
        let gitMetadata = repository.appending(".git")
        if !FileManager.default.fileExists(atPath: gitMetadata.string) {
            if FileManager.default.fileExists(
                atPath: repository.string)
            {
                throw RuntimeFailure.invalidOutput(
                    "refusing to replace non-git checkout "
                        + repository.string)
            }
            try FileManager.default.createDirectory(
                atPath: repository.removingLastComponent().string,
                withIntermediateDirectories: true)
            var cloneArguments = ["clone"]
            if partialClone {
                cloneArguments += [
                    "--filter=blob:none",
                    "--no-tags",
                    "--single-branch",
                ]
                switch reference {
                case .branch(let branch), .tag(let branch):
                    cloneArguments += ["--branch", branch]
                case .commit:
                    break
                }
            }
            cloneArguments += [remote, repository.string]
            try await git(
                cloneArguments,
                workingDirectory:
                    repository.removingLastComponent())
        }
        if partialClone {
            try await git(
                [
                    "-C", repository.string,
                    "config", "remote.origin.promisor", "true",
                ],
                workingDirectory: repository)
            try await git(
                [
                    "-C", repository.string,
                    "config", "remote.origin.partialclonefilter", "blob:none",
                ],
                workingDirectory: repository)
            try await git(
                [
                    "-C", repository.string,
                    "config", "remote.origin.tagOpt", "--no-tags",
                ],
                workingDirectory: repository)
        }
        switch reference {
        case .branch(let branch):
            try await git(
                (partialClone
                    ? [
                        "-C", repository.string,
                        "fetch", "--filter=blob:none", "--no-tags",
                        "origin", branch,
                    ]
                    : [
                        "-C", repository.string,
                        "fetch", "origin", branch,
                    ]),
                workingDirectory: repository)
            try await git(
                [
                    "-C", repository.string,
                    "reset", "--hard", "FETCH_HEAD",
                ],
                workingDirectory: repository)
        case .tag(let tag):
            try await git(
                (partialClone
                    ? [
                        "-C", repository.string,
                        "fetch", "--filter=blob:none", "--no-tags", "origin",
                        "refs/tags/\(tag):refs/tags/\(tag)",
                    ]
                    : [
                        "-C", repository.string,
                        "fetch", "--tags", "origin", tag,
                    ]),
                workingDirectory: repository)
            try await git(
                [
                    "-C", repository.string,
                    "reset", "--hard", tag,
                ],
                workingDirectory: repository)
        case .commit(let commit):
            try await git(
                [
                    "-C", repository.string,
                    "fetch", "--depth", "1", "origin", commit,
                ],
                workingDirectory: repository)
            try await git(
                [
                    "-C", repository.string,
                    "reset", "--hard", commit,
                ],
                workingDirectory: repository)
        }
        try await git(
            [
                "-C", repository.string,
                "clean", "-fd",
            ],
            workingDirectory: repository)
    }
}

private enum ManagedSourceReference {
    case branch(String)
    case tag(String)
    case commit(String)
}
