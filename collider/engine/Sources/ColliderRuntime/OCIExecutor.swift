import ColliderCore
import Foundation
import SystemPackage

enum OCIExecutorResolver {
    static func resolve(
        runner: RunnerPlatform = .current,
        executionPlatform: ExecutionPlatform
    ) throws -> AppleContainerExecutor {
        guard executionPlatform.environment == .oci,
            executionPlatform.operatingSystem == .linux
        else {
            throw OCIExecutorFailure.unsupportedExecutionPlatform(
                executionPlatform)
        }

        guard runner.operatingSystem == .macOS,
            runner.architecture == .arm64
        else {
            throw OCIExecutorFailure.unsupportedRunner(runner)
        }
        return AppleContainerExecutor()
    }
}

struct AppleContainerExecutor: Sendable {
    let backend = ExecutionBackend.appleContainer
    let executable = CommandSpec.Executable.named("container")

    func buildImageCommand(
        _ preparation: OCIImagePreparation,
        candidate: FilePath
    ) throws -> CommandSpec {
        try validateOCIPlatform(preparation.executionPlatform)
        return CommandSpec(
            executable: executable,
            arguments: [
                "build",
                "--platform", ociPlatformName(preparation.executionPlatform),
                "--pull",
                "--tag", preparation.imageName,
                "--file", preparation.containerFile.string,
                preparation.context.string,
            ],
            workingDirectory: preparation.context,
            environment: preparation.environment,
            output: .logged)
    }

    func inspectImageCommand(
        _ preparation: OCIImagePreparation
    ) -> CommandSpec? {
        CommandSpec(
            executable: executable,
            arguments: ["image", "inspect", preparation.imageName],
            workingDirectory: preparation.context,
            environment: preparation.environment,
            output: .captured(limit: 4 * 1_024 * 1_024))
    }

    func imageIdentifier(
        candidate: FilePath,
        inspectionOutput: String?
    ) throws -> String {
        guard let inspectionOutput,
            let data = inspectionOutput.data(using: .utf8),
            let images = try? JSONDecoder().decode(
                [AppleImageInspection].self,
                from: data),
            images.count == 1
        else {
            throw OCIExecutorFailure.invalidAppleImageInspection
        }
        let image = images[0].configuration
        return image.name + "\n" + image.descriptor.digest
    }

    func removeImageCommand(
        _ imageID: String,
        preparation: OCIImagePreparation
    ) -> CommandSpec? {
        nil
    }

    func containerName(for execution: OCIExecution) throws -> String {
        try validateExecutionPolicies(execution)
        return
            execution.hostname + "-"
            + UUID().uuidString.prefix(12).lowercased()
    }
}

private struct AppleImageInspection: Decodable {
    struct Configuration: Decodable {
        struct Descriptor: Decodable {
            let digest: String
        }

        let descriptor: Descriptor
        let name: String
    }

    let configuration: Configuration
}

func appleImageReference(_ identifier: String) -> String {
    String(identifier.split(separator: "\n", maxSplits: 1)[0])
}

private func validateOCIPlatform(
    _ platform: ExecutionPlatform
) throws {
    guard platform.environment == .oci,
        platform.operatingSystem == .linux
    else {
        throw OCIExecutorFailure.unsupportedExecutionPlatform(platform)
    }
}

private func validateExecutionPolicies(
    _ execution: OCIExecution
) throws {
    try validateOCIPlatform(execution.executionPlatform)
    guard execution.networkPolicy == .externalDisabled,
        execution.capabilityPolicy == .dropAll,
        execution.privilegePolicy == .prohibitAcquisition,
        execution.resourceLimits.processCount > 0
    else {
        throw OCIExecutorFailure.unsupportedPolicy
    }
    if execution.intelBinaryTranslationPolicy == .required {
        guard execution.executionPlatform == .linuxARM64OCI else {
            throw OCIExecutorFailure.invalidIntelBinaryTranslationContract
        }
    }
}

private func ociPlatformName(_ platform: ExecutionPlatform) -> String {
    let architecture =
        switch platform.architecture {
        case .arm64: "arm64"
        case .x86_64: "amd64"
        }
    return "\(platform.operatingSystem.rawValue)/\(architecture)"
}

enum OCIExecutorFailure: Error, CustomStringConvertible {
    case containerCleanupFailed(name: String, reason: String)
    case invalidAppleImageInspection
    case invalidIntelBinaryTranslationContract
    case unsupportedTerminalOutput
    case unsupportedExecutionPlatform(ExecutionPlatform)
    case unsupportedPolicy
    case unsupportedRunner(RunnerPlatform)

    var description: String {
        switch self {
        case .containerCleanupFailed(let name, let reason):
            "Apple container cleanup failed for \(name): \(reason)"
        case .invalidAppleImageInspection:
            "Apple container image inspection did not return one OCI digest"
        case .invalidIntelBinaryTranslationContract:
            "Intel Linux binary translation requires an ARM64 Linux OCI execution platform"
        case .unsupportedTerminalOutput:
            "Apple container lifecycle execution does not support terminal output"
        case .unsupportedExecutionPlatform(let platform):
            "unsupported OCI execution platform: "
                + "\(platform.environment.rawValue)/"
                + "\(platform.operatingSystem.rawValue)/"
                + platform.architecture.rawValue
        case .unsupportedPolicy:
            "OCI executor requires external networking disabled, all capabilities "
                + "dropped, privilege acquisition prohibited, and a process limit"
        case .unsupportedRunner(let runner):
            "unsupported OCI runner: \(runner.operatingSystem.rawValue)/"
                + runner.architecture.rawValue
        }
    }
}
