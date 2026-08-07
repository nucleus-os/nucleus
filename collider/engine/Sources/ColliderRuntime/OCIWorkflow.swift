import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareOCIImage(
        _ preparation: OCIImagePreparation,
        stage: TaskID?
    ) async throws {
        try validateOCIPlatform(preparation.executionPlatform)
        let contents = try String(
            contentsOfFile: preparation.containerFile.string,
            encoding: .utf8)
        let base = contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("FROM ") }
        guard let base, base.contains("@sha256:") else {
            throw RuntimeFailure.invalidOutput(
                "build Containerfile must select its base image by digest")
        }

        let parent = preparation.imageID.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        let imageID = try await ociBackend.prepareImage(preparation)
        guard validOCIImageDigest(in: imageID) != nil else {
            throw RuntimeFailure.invalidOutput(
                "OCI executor did not produce a content-addressed builder image ID")
        }
        try DurableFile.write(Data("\(imageID)\n".utf8), to: preparation.imageID)
    }

    func runOCI(
        _ execution: OCIExecution,
        stage: TaskID?
    ) async throws {
        let result = try await executeOCI(execution, stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
    }

    func executeOCI(
        _ execution: OCIExecution,
        stage: TaskID?
    ) async throws -> CommandResult {
        try validateExecutionPolicies(execution)
        let imageID = try String(
            contentsOfFile: execution.imageID.string,
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard validOCIImageDigest(in: imageID) != nil else {
            throw RuntimeFailure.invalidOutput(
                "builder image ID is missing or invalid")
        }
        guard execution.workingDirectory.hasPrefix("/"),
            !execution.hostname.isEmpty,
            !execution.command.isEmpty
        else {
            throw RuntimeFailure.invalidOutput(
                "invalid OCI execution contract")
        }

        var targets: Set<String> = ["/tmp", ociConfiguration.guestHome]
        for mount in execution.mounts {
            guard mount.target.hasPrefix("/"),
                !mount.target.contains(".."),
                targets.insert(mount.target).inserted
            else {
                throw RuntimeFailure.invalidOutput(
                    "invalid or duplicate OCI mount: \(mount.target)")
            }
            if mount.access == .readWrite {
                try FileManager.default.createDirectory(
                    atPath: mount.source.string,
                    withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: mount.source.string) {
                throw RuntimeFailure.invalidOutput(
                    "read-only OCI input is missing: \(mount.source)")
            }
        }

        let temporaryDirectory: FilePath?
        if let root = execution.temporaryDirectory {
            try FileManager.default.createDirectory(
                atPath: root.string,
                withIntermediateDirectories: true)
            let candidate = root.appending(UUID().uuidString)
            try FileManager.default.createDirectory(
                atPath: candidate.string,
                withIntermediateDirectories: false)
            temporaryDirectory = candidate
        } else {
            temporaryDirectory = nil
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(
                    atPath: temporaryDirectory.string)
            }
        }

        let output =
            taskOutputPresentation?.output(for: execution.output)
            ?? execution.output
        return try await ociBackend.execute(
            OCIRuntimeExecutionRequest(
                execution: execution,
                imageReference: ociImageReference(imageID),
                temporaryDirectory: temporaryDirectory,
                output: output,
                logging: logging,
                stage: stage,
                cancellation: cancellation,
                configuration: ociConfiguration))
    }
}

func validOCIImageDigest(in identifier: String) -> String? {
    let digest = identifier.split(whereSeparator: \.isNewline).last.map(String.init)
    guard let digest, digest.hasPrefix("sha256:"), digest.count == 71 else {
        return nil
    }
    return digest
}
