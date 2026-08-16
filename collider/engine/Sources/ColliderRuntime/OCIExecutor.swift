import ColliderCore
import Foundation

package func ociImageReference(_ identifier: String) -> String {
    String(identifier.split(separator: "\n", maxSplits: 1)[0])
}

package func validateOCIPlatform(
    _ platform: ExecutionPlatform
) throws {
    guard platform.environment == .oci,
        platform.operatingSystem == .linux
    else {
        throw OCIExecutorFailure.unsupportedExecutionPlatform(platform)
    }
}

func validateExecutionPolicies(
    _ execution: OCIExecution
) throws {
    try validateOCIPlatform(execution.executionPlatform)
    guard execution.capabilityPolicy == .dropAll,
        execution.privilegePolicy == .prohibitAcquisition,
        execution.resourceLimits.processCount > 0
    else {
        throw OCIExecutorFailure.unsupportedPolicy
    }
    let foreignArchitectures = Set(
        execution.executableRequirements.lazy
            .map(\.architecture)
            .filter { $0 != execution.executionPlatform.architecture })
    if !foreignArchitectures.isEmpty {
        guard execution.executionPlatform == .linuxARM64OCI,
            foreignArchitectures == [.x86_64]
        else {
            throw OCIExecutorFailure.invalidExecutableArchitectureContract
        }
    }
}

package func ociPlatformName(_ platform: ExecutionPlatform) -> String {
    let architecture =
        switch platform.architecture {
        case .arm64: "arm64"
        case .x86_64: "amd64"
        }
    return "\(platform.operatingSystem.rawValue)/\(architecture)"
}

package enum OCIExecutorFailure: Error, CustomStringConvertible {
    case invalidExecutableArchitectureContract
    case unsupportedExecutionPlatform(ExecutionPlatform)
    case unsupportedPolicy
    case unsupportedRunner(RunnerPlatform)

    package var description: String {
        switch self {
        case .invalidExecutableArchitectureContract:
            "OCI executable requirements cannot be satisfied by this execution platform"
        case .unsupportedExecutionPlatform(let platform):
            "unsupported OCI execution platform: "
                + "\(platform.environment.rawValue)/"
                + "\(platform.operatingSystem.rawValue)/"
                + platform.architecture.rawValue
        case .unsupportedPolicy:
            "OCI executor requires all capabilities dropped, privilege acquisition "
                + "prohibited, and a process limit"
        case .unsupportedRunner(let runner):
            "unsupported OCI runner: \(runner.operatingSystem.rawValue)/"
                + runner.architecture.rawValue
        }
    }
}
