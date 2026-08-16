import ColliderCore
import SystemPackage

let chromiumToolResourceLimits = OCIResourceLimits(
    cpuCount: 4,
    memoryBytes: 8 * 1_024 * 1_024 * 1_024,
    processCount: 4_096)

let chromiumBuildExecutableRequirements: Set<OCIExecutableRequirement> = [
    OCIExecutableRequirement(
        architecture: .x86_64,
        executable: "/source/chromium/src/buildtools/linux64/gn"),
    OCIExecutableRequirement(
        architecture: .x86_64,
        executable: "/source/chromium/src/third_party/siso/cipd/siso"),
    OCIExecutableRequirement(
        architecture: .x86_64,
        executable:
            "/source/chromium/src/third_party/llvm-build/Linux_x64/bin/clang++"),
]

func chromiumToolExecution(
    target: ChromiumLinuxTarget,
    entrypoint: OCIMountedEntrypoint,
    hostname: String,
    workingDirectory: String,
    hostWorkingDirectory: FilePath,
    mounts: [OCIMount],
    persistentWorkspaceMounts: [OCIPersistentWorkspaceMount] = [],
    command: [String],
    environment: [String: String],
    output: CommandSpec.Output = .logged
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: entrypoint.image.path,
        hostname: hostname,
        workingDirectory: workingDirectory,
        hostWorkingDirectory: hostWorkingDirectory,
        mounts: [entrypoint.mount] + mounts,
        persistentWorkspaceMounts: persistentWorkspaceMounts,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
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
        imageEntrypointOverride: entrypoint.containerPath,
        command: command,
        environment: environment,
        output: output)
}
