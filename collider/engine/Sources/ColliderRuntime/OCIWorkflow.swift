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
        guard let base else {
            throw RuntimeFailure.invalidOutput(
                "build Containerfile must select a base image")
        }
        let baseReference = base.dropFirst("FROM ".count)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        switch preparation.baseImageSource {
        case .registry:
            guard preparation.localBaseImageID == nil,
                let baseReference,
                baseReference.contains("@sha256:"),
                !baseReference.hasPrefix("localhost/")
            else {
                throw RuntimeFailure.invalidOutput(
                    "registry-backed Containerfile must select its base image by digest")
            }
        case .local:
            let localBase = try ociLocalBaseImage(preparation)
            guard baseReference == localBase.buildReference else {
                throw RuntimeFailure.invalidOutput(
                    "local Containerfile must select its verified digest tag")
            }
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
        try result.result.requireSuccess(reason: "container command failed")
    }

    func executeOCI(
        _ execution: OCIExecution,
        stage: TaskID?,
        operationName: String? = nil
    ) async throws -> OCIRuntimeExecutionOutcome {
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

        let reservedTargets = [FilePath("/tmp"), FilePath(ociConfiguration.guestHome)]
        var bindTargets: [(path: FilePath, isReadOnly: Bool)] = []
        var persistentTargets: [FilePath] = []
        func normalizedMountTarget(_ rawTarget: String) throws -> FilePath {
            let target = FilePath(rawTarget).lexicallyNormalized()
            guard rawTarget.hasPrefix("/"), rawTarget != "/",
                !rawTarget.split(separator: "/").contains(".."),
                target.string == rawTarget,
                !reservedTargets.contains(where: { $0.overlaps(target) })
            else {
                throw RuntimeFailure.invalidOutput(
                    "invalid, duplicate, or overlapping OCI mount: \(rawTarget)")
            }
            return target
        }
        for mount in execution.mounts {
            let target = try normalizedMountTarget(mount.target)
            guard
                !bindTargets.contains(where: {
                    $0.path == target
                        || ($0.path.overlaps(target)
                            && (!$0.isReadOnly || !mount.isReadOnly))
                })
            else {
                throw RuntimeFailure.invalidOutput(
                    "invalid, duplicate, or overlapping OCI mount: \(mount.target)")
            }
            bindTargets.append((target, mount.isReadOnly))
            if !mount.isReadOnly {
                try FileManager.default.createDirectory(
                    atPath: mount.source.string,
                    withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: mount.source.string) {
                throw RuntimeFailure.invalidOutput(
                    "read-only OCI input is missing: \(mount.source)")
            }
        }
        for mount in execution.persistentWorkspaceMounts {
            let target = try normalizedMountTarget(mount.target)
            let isReadOnly = mount.access == .readOnly
            guard
                !bindTargets.contains(where: {
                    guard $0.path.overlaps(target) else { return false }
                    if $0.path == target { return true }
                    // The inner mount hides part of the outer one, which is
                    // safe only when nothing writes the outer through the
                    // region now hidden. Either may be the inner: a writable
                    // output workspace sits inside the read-only AOSP source,
                    // and the read-only device tree sits inside that same
                    // source. Requiring the workspace to be the inner one
                    // rejected the second arrangement outright.
                    if target.string.hasPrefix($0.path.string + "/") {
                        return !$0.isReadOnly
                    }
                    return !isReadOnly
                }),
                !persistentTargets.contains(where: { $0.overlaps(target) })
            else {
                throw RuntimeFailure.invalidOutput(
                    "invalid, duplicate, or overlapping OCI mount: \(mount.target)")
            }
            persistentTargets.append(target)
        }

        let output =
            taskOutputPresentation?.output(for: execution.output)
            ?? execution.output
        let command = CredentialScrubber.command(execution.command)
        let logPath: String?
        if let logging, let stage {
            logPath = await logging.registry.stageLogPath(
                for: stage,
                in: logging.run
            ).string
        } else {
            logPath = nil
        }
        let context = OperationContext(
            task: stage,
            operation: operationName ?? "container command",
            command: command,
            invocation: CredentialScrubber.renderedCommand(command),
            workingDirectory: execution.workingDirectory,
            logPath: logPath)
        if let logging {
            try? await logging.registry.record(
                .operation(.started(context)),
                in: logging.run)
        }
        let request = OCIRuntimeExecutionRequest(
            execution: execution,
            imageReference: ociImageReference(imageID),
            output: output,
            logging: logging,
            stage: stage,
            cancellation: cancellation,
            configuration: ociConfiguration,
            taskOutputPresentation: taskOutputPresentation ?? .verbose,
            taskOutputObserver: taskOutputObserver)
        do {
            let outcome = try await ociBackend.execute(request)
            let result = outcome.result.recordingExecutionContext(context)
            if let logging {
                try? await logging.registry.record(
                    .operation(
                        .finished(
                            OperationResult(
                                context: context,
                                status: result.status,
                                signal: result.signal,
                                timedOut: result.timedOut))),
                    in: logging.run)
            }
            return OCIRuntimeExecutionOutcome(
                result: result,
                timings: outcome.timings)
        } catch {
            let failure =
                if let structured = error as? ExecutionFailure {
                    structured.addingContext(task: stage, logPath: logPath)
                } else {
                    ExecutionFailure(
                        task: stage,
                        operation: context.operation,
                        command: command,
                        invocation: context.invocation,
                        workingDirectory: context.workingDirectory,
                        logPath: logPath,
                        reason: String(describing: error))
                }
            if let logging {
                try? await logging.registry.record(
                    .operation(.failed(failure)),
                    in: logging.run)
            }
            if error is CancellationError { throw error }
            throw failure
        }
    }
}

package struct OCILocalBaseImage: Hashable, Sendable {
    package let sourceReference: String
    package let digest: String
    package let buildReference: String
}

package func ociLocalBaseImage(
    _ preparation: OCIImagePreparation
) throws -> OCILocalBaseImage {
    guard preparation.baseImageSource == .local,
        let identifier = preparation.localBaseImageID
    else {
        throw RuntimeFailure.invalidOutput(
            "local OCI base image ID is missing")
    }
    let components = try String(
        contentsOfFile: identifier.string,
        encoding: .utf8
    ).split(whereSeparator: \.isNewline).map(String.init)
    guard components.count == 2 else {
        throw RuntimeFailure.invalidOutput(
            "local OCI base image ID is invalid")
    }
    let sourceReference = components[0]
    let digest = components[1]
    guard sourceReference.hasPrefix("localhost/"),
        !sourceReference.contains(":"),
        !sourceReference.contains(where: { $0.isWhitespace || $0 == "@" }),
        digest.hasPrefix("sha256:"),
        digest.count == 71,
        digest.dropFirst("sha256:".count).allSatisfy({ $0.isHexDigit })
    else {
        throw RuntimeFailure.invalidOutput(
            "local OCI base image ID is invalid")
    }
    return OCILocalBaseImage(
        sourceReference: sourceReference,
        digest: digest,
        buildReference: sourceReference + ":digest-"
            + digest.dropFirst("sha256:".count))
}

func validOCIImageDigest(in identifier: String) -> String? {
    let digest = identifier.split(whereSeparator: \.isNewline).last.map(String.init)
    guard let digest, digest.hasPrefix("sha256:"), digest.count == 71 else {
        return nil
    }
    return digest
}
