import ColliderCore
import Foundation

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

    func containerName(for execution: OCIExecution) throws -> String {
        try validateExecutionPolicies(execution)
        return
            execution.hostname + "-"
            + UUID().uuidString.prefix(12).lowercased()
    }
}

func appleImageReference(_ identifier: String) -> String {
    String(identifier.split(separator: "\n", maxSplits: 1)[0])
}

func validateOCIPlatform(
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
    guard execution.capabilityPolicy == .dropAll,
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

func ociPlatformName(_ platform: ExecutionPlatform) -> String {
    let architecture =
        switch platform.architecture {
        case .arm64: "arm64"
        case .x86_64: "amd64"
        }
    return "\(platform.operatingSystem.rawValue)/\(architecture)"
}

enum OCIExecutorFailure: Error, CustomStringConvertible {
    case containerBuilderReleaseFailed(operation: String, cleanup: String)
    case containerCleanupFailed(name: String, reason: String)
    case containerSuspensionFailed(name: String, reason: String)
    case invalidAppleImageDigest
    case invalidIntelBinaryTranslationContract
    case unsupportedTerminalOutput
    case unsupportedExecutionPlatform(ExecutionPlatform)
    case unsupportedPolicy
    case unsupportedRunner(RunnerPlatform)

    var description: String {
        switch self {
        case .containerBuilderReleaseFailed(let operation, let cleanup):
            "Apple container image preparation failed (\(operation)) and the "
                + "ephemeral builder could not be released (\(cleanup))"
        case .containerCleanupFailed(let name, let reason):
            "Apple container cleanup failed for \(name): \(reason)"
        case .containerSuspensionFailed(let name, let reason):
            "Apple container suspension failed for \(name): \(reason)"
        case .invalidAppleImageDigest:
            "Apple container image API did not return one OCI digest"
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
