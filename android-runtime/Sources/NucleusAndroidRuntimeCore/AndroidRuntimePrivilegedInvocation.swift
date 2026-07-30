public enum AndroidRuntimePrivilegedOperation {
    public static let apexMountCommandName = "__android-apex-mount"
    public static let bpfBrokerCommandName = "__android-bpf-broker"
    public static let bpfMountCommandName = "__android-bpf-mount"
    public static let cgroupDelegateCommandName =
        "__android-cgroup-delegate"
    public static let containerSupervisorCommandName =
        "__android-container-supervise"
}

public enum AndroidRuntimeApexPayloadFileSystem:
    String, CaseIterable, Equatable, Sendable
{
    case erofs
    case ext4
}

public struct AndroidApexMountInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(
        helperExecutable: String,
        rootFileSystem: String,
        source: String,
        target: String,
        payloadFileSystem: AndroidRuntimeApexPayloadFileSystem,
        payloadOffset: UInt64
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            helperExecutable,
            AndroidRuntimePrivilegedOperation.apexMountCommandName,
            "--root-file-system",
            rootFileSystem,
            "--source",
            source,
            "--target",
            target,
            "--payload-file-system",
            payloadFileSystem.rawValue,
            "--payload-offset",
            String(payloadOffset),
        ]
    }
}

public struct AndroidBPFBrokerInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(
        helperExecutable: String,
        socket: String,
        rootUID: UInt32,
        rootGID: UInt32
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            helperExecutable,
            AndroidRuntimePrivilegedOperation.bpfBrokerCommandName,
            "--socket",
            socket,
            "--root-uid",
            String(rootUID),
            "--root-gid",
            String(rootGID),
        ]
    }
}

public struct AndroidContainerSupervisorInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(
        helperExecutable: String,
        ownerProcessIdentifier: Int32,
        name: String,
        configuration: String,
        logFile: String
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            helperExecutable,
            AndroidRuntimePrivilegedOperation.containerSupervisorCommandName,
            "--owner-pid",
            String(ownerProcessIdentifier),
            "--container",
            name,
            "--configuration",
            configuration,
            "--log-file",
            logFile,
        ]
    }
}
