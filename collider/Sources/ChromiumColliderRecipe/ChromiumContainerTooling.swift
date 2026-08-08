import ColliderCore
import SystemPackage

let chromiumToolResourceLimits = OCIResourceLimits(
    cpuCount: 4,
    memoryBytes: 8 * 1_024 * 1_024 * 1_024,
    processCount: 4_096)

func chromiumToolExecution(
    imageID: FilePath,
    hostname: String,
    workingDirectory: String,
    hostWorkingDirectory: FilePath,
    mounts: [OCIMount],
    temporaryDirectory: FilePath,
    command: [String],
    environment: [String: String],
    output: CommandSpec.Output = .logged
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        imageID: imageID,
        hostname: hostname,
        workingDirectory: workingDirectory,
        hostWorkingDirectory: hostWorkingDirectory,
        mounts: mounts,
        temporaryDirectory: temporaryDirectory,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: .required,
        resourceLimits: chromiumToolResourceLimits,
        containerEnvironment: [
            "DEPOT_TOOLS_UPDATE": "0",
            "HOME": "/tmp/nucleus-home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
        ],
        command: command,
        environment: environment,
        output: output)
}
