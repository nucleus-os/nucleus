import ColliderCore
import Foundation
import SystemPackage

#if os(macOS)
import ContainerAPIClient
import ContainerBuild
#endif

#if os(macOS)
extension ColliderRuntime {
    func prepareOCIImage(
        _ preparation: OCIImagePreparation,
        stage: TaskID?
    ) async throws {
        let suspension = AppleContainerSuspension(
            client: ContainerClient(),
            name: Builder.builderContainerId)
        do {
            try await prepareOCIImageKeepingBuilder(preparation, stage: stage)
        } catch {
            let preparationError = error
            do {
                try await suspension.stopAndVerify()
            } catch {
                throw OCIExecutorFailure.containerBuilderReleaseFailed(
                    operation: String(describing: preparationError),
                    cleanup: String(describing: error))
            }
            throw preparationError
        }
        try await suspension.stopAndVerify()
    }

    private func prepareOCIImageKeepingBuilder(
        _ preparation: OCIImagePreparation,
        stage: TaskID?
    ) async throws {
        let executor = try OCIExecutorResolver.resolve(
            executionPlatform: preparation.executionPlatform)
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
        let candidate = parent.appending(
            ".image-id.candidate-\(UUID().uuidString)")
        let previousImageID = try? String(
            contentsOfFile: preparation.imageID.string,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: candidate.string) }

        let result = try await execute(
            try executor.buildImageCommand(
                preparation,
                candidate: candidate),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
        let inspectionOutput: String?
        if let command = executor.inspectImageCommand(preparation) {
            let inspection = try await execute(command, stage: stage)
            guard inspection.status == 0 else {
                throw RuntimeFailure.commandFailed(status: inspection.status)
            }
            inspectionOutput = inspection.standardOutput
        } else {
            inspectionOutput = nil
        }
        let imageID = try executor.imageIdentifier(
            candidate: candidate,
            inspectionOutput: inspectionOutput)
        guard validOCIImageDigest(in: imageID) != nil else {
            throw RuntimeFailure.invalidOutput(
                "OCI executor did not produce a content-addressed builder image ID")
        }
        try DurableFile.write(Data("\(imageID)\n".utf8), to: preparation.imageID)
        if let previousImageID,
            previousImageID != imageID,
            validOCIImageDigest(in: previousImageID) != nil,
            let remove = executor.removeImageCommand(
                previousImageID,
                preparation: preparation)
        {
            _ = try? await execute(remove, stage: stage)
        }
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
        let executor = try OCIExecutorResolver.resolve(
            executionPlatform: execution.executionPlatform)
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

        var targets: Set<String> = ["/tmp", "/home/nucleus-build"]
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

        let name = try executor.containerName(for: execution)
        let output =
            taskOutputPresentation?.output(for: execution.output)
            ?? execution.output
        return try await AppleContainerLifecycle().execute(
            execution,
            name: name,
            imageReference: appleImageReference(imageID),
            temporaryDirectory: temporaryDirectory,
            output: output,
            logging: logging,
            stage: stage)
    }
}
#else
extension ColliderRuntime {
    func prepareOCIImage(
        _ preparation: OCIImagePreparation,
        stage: TaskID?
    ) async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    func runOCI(
        _ execution: OCIExecution,
        stage: TaskID?
    ) async throws {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }

    func executeOCI(
        _ execution: OCIExecution,
        stage: TaskID?
    ) async throws -> CommandResult {
        throw OCIExecutorFailure.unsupportedRunner(.current)
    }
}
#endif

private func validOCIImageDigest(in identifier: String) -> String? {
    let digest = identifier.split(whereSeparator: \.isNewline).last.map(String.init)
    guard let digest, digest.hasPrefix("sha256:"), digest.count == 71 else {
        return nil
    }
    return digest
}
