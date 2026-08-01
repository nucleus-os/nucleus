import ColliderCore
import Foundation
import SystemPackage

protocol OCIExecutor: Sendable {
    var backend: ExecutionBackend { get }
    var executable: CommandSpec.Executable { get }

    func buildImageCommand(
        _ preparation: OCIImagePreparation,
        candidate: FilePath
    ) throws -> CommandSpec

    func inspectImageCommand(
        _ preparation: OCIImagePreparation
    ) -> CommandSpec?

    func imageIdentifier(
        candidate: FilePath,
        inspectionOutput: String?
    ) throws -> String

    func removeImageCommand(
        _ imageID: String,
        preparation: OCIImagePreparation
    ) -> CommandSpec

    func runCommand(
        _ execution: OCIExecution,
        imageID: String,
        temporaryDirectory: FilePath?
    ) throws -> CommandSpec
}

enum OCIExecutorResolver {
    static func resolve(
        runner: RunnerPlatform = .current,
        executionPlatform: ExecutionPlatform
    ) throws -> any OCIExecutor {
        guard executionPlatform.environment == .oci,
            executionPlatform.operatingSystem == .linux,
            executionPlatform.architecture == .x86_64
        else {
            throw OCIExecutorFailure.unsupportedExecutionPlatform(
                executionPlatform)
        }

        switch (runner.operatingSystem, runner.architecture) {
        case (.linux, .x86_64):
            return PodmanExecutor()
        case (.macOS, .arm64):
            return AppleContainerExecutor()
        default:
            throw OCIExecutorFailure.unsupportedRunner(runner)
        }
    }
}

struct PodmanExecutor: OCIExecutor {
    let backend = ExecutionBackend.podman
    let executable = CommandSpec.Executable.named("podman")

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
                "--pull=always",
                "--tag", preparation.imageName,
                "--iidfile", candidate.string,
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
        nil
    }

    func imageIdentifier(
        candidate: FilePath,
        inspectionOutput: String?
    ) throws -> String {
        try String(contentsOfFile: candidate.string, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeImageCommand(
        _ imageID: String,
        preparation: OCIImagePreparation
    ) -> CommandSpec {
        CommandSpec(
            executable: executable,
            arguments: ["image", "rm", imageID],
            workingDirectory: preparation.context,
            environment: preparation.environment,
            output: .logged)
    }

    func runCommand(
        _ execution: OCIExecution,
        imageID: String,
        temporaryDirectory: FilePath?
    ) throws -> CommandSpec {
        try validateExecutionPolicies(execution)
        var arguments = [
            "run",
            "--rm",
            "--platform=\(ociPlatformName(execution.executionPlatform))",
            "--network=none",
            "--userns=keep-id:uid=\(execution.userPolicy.userID),gid=\(execution.userPolicy.groupID)",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
            "--hostname=\(execution.hostname)",
            "--read-only",
            "--pids-limit=\(execution.resourceLimits.processCount)",
            "--tmpfs=/home/nucleus-build:rw,nosuid,nodev,noexec,size=1g",
            "--workdir=\(execution.workingDirectory)",
        ]
        if let cpuCount = execution.resourceLimits.cpuCount {
            arguments.append("--cpus=\(cpuCount)")
        }
        if let memoryBytes = execution.resourceLimits.memoryBytes {
            arguments.append("--memory=\(memoryBytes)b")
        }
        if execution.processFilesystemPolicy == .unmasked {
            arguments.append("--security-opt=unmask=/proc/*")
        }
        if let temporaryDirectory {
            arguments += [
                "--mount",
                "type=bind,src=\(temporaryDirectory),target=/tmp,rw=true",
            ]
        } else {
            arguments.append("--tmpfs=/tmp:rw,nosuid,nodev,size=8g")
        }
        for (name, value) in execution.containerEnvironment.sorted(by: {
            $0.key < $1.key
        }) {
            arguments += ["--env", "\(name)=\(value)"]
        }
        for mount in execution.mounts {
            let writable = mount.access == .readWrite ? "rw=true" : "ro=true"
            arguments += [
                "--mount",
                "type=bind,src=\(mount.source),target=\(mount.target),\(writable)",
            ]
        }
        arguments.append(imageID)
        arguments += execution.command
        return CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: execution.hostWorkingDirectory,
            environment: execution.environment,
            output: execution.output)
    }
}

struct AppleContainerExecutor: OCIExecutor {
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
    ) -> CommandSpec {
        CommandSpec(
            executable: executable,
            arguments: [
                "image", "delete", "--force", appleImageReference(imageID),
            ],
            workingDirectory: preparation.context,
            environment: preparation.environment,
            output: .logged)
    }

    func runCommand(
        _ execution: OCIExecution,
        imageID: String,
        temporaryDirectory: FilePath?
    ) throws -> CommandSpec {
        try validateExecutionPolicies(execution)
        var arguments = [
            "run",
            "--rm",
            "--platform", ociPlatformName(execution.executionPlatform),
            "--rosetta",
            "--network", OCIBackendContract.appleOfflineNetwork,
            "--no-dns",
            "--uid", String(execution.userPolicy.userID),
            "--gid", String(execution.userPolicy.groupID),
            "--cap-drop", "ALL",
            "--name", execution.hostname,
            "--read-only",
            "--ulimit",
            "nproc=\(execution.resourceLimits.processCount):\(execution.resourceLimits.processCount)",
            "--tmpfs", "/home/nucleus-build",
            "--workdir", execution.workingDirectory,
        ]
        if let cpuCount = execution.resourceLimits.cpuCount {
            arguments += ["--cpus", String(cpuCount)]
        }
        if let memoryBytes = execution.resourceLimits.memoryBytes {
            arguments += ["--memory", String(memoryBytes)]
        }
        if let temporaryDirectory {
            arguments += [
                "--mount",
                "type=bind,source=\(temporaryDirectory),target=/tmp",
            ]
        } else {
            arguments += ["--tmpfs", "/tmp"]
        }
        for (name, value) in execution.containerEnvironment.sorted(by: {
            $0.key < $1.key
        }) {
            arguments += ["--env", "\(name)=\(value)"]
        }
        for mount in execution.mounts {
            var specification =
                "type=bind,source=\(mount.source),target=\(mount.target)"
            if mount.access == .readOnly {
                specification += ",readonly"
            }
            arguments += ["--mount", specification]
        }
        arguments.append(appleImageReference(imageID))
        arguments += execution.command
        return CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: execution.hostWorkingDirectory,
            environment: execution.environment,
            output: execution.output)
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

private func appleImageReference(_ identifier: String) -> String {
    String(identifier.split(separator: "\n", maxSplits: 1)[0])
}

private func validateOCIPlatform(
    _ platform: ExecutionPlatform
) throws {
    guard platform == .linuxAMD64OCI else {
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
    case invalidAppleImageInspection
    case unsupportedExecutionPlatform(ExecutionPlatform)
    case unsupportedPolicy
    case unsupportedRunner(RunnerPlatform)

    var description: String {
        switch self {
        case .invalidAppleImageInspection:
            "Apple container image inspection did not return one OCI digest"
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
