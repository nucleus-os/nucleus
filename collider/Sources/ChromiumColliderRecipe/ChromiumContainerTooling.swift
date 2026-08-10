import ColliderCore
import SystemPackage

let chromiumToolResourceLimits = OCIResourceLimits(
    cpuCount: 4,
    memoryBytes: 8 * 1_024 * 1_024 * 1_024,
    processCount: 4_096)

func chromiumToolExecution(
    target: ChromiumLinuxTarget,
    imageID: FilePath,
    hostname: String,
    workingDirectory: String,
    hostWorkingDirectory: FilePath,
    mounts: [OCIMount],
    persistentWorkspaceMounts: [OCIPersistentWorkspaceMount] = [],
    temporaryDirectory: FilePath,
    command: [String],
    environment: [String: String],
    output: CommandSpec.Output = .logged
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: imageID,
        hostname: hostname,
        workingDirectory: workingDirectory,
        hostWorkingDirectory: hostWorkingDirectory,
        mounts: mounts,
        persistentWorkspaceMounts: persistentWorkspaceMounts,
        temporaryDirectory: temporaryDirectory,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        // Chromium's Linux clang bundle and some checked-in tools remain x86_64.
        intelBinaryTranslationPolicy: .required,
        resourceLimits: chromiumToolResourceLimits,
        containerEnvironment: [
            "DEPOT_TOOLS_UPDATE": "0",
            "HOME": "/tmp/nucleus-home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH":
                "/source/chromium/src/third_party/depot_tools:"
                + "/source/chromium/src/third_party/llvm-build/Linux_x64/bin:"
                + "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
        ],
        command: command,
        environment: environment,
        output: output)
}
