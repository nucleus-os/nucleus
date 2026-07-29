import ColliderAndroidPrivileged

let androidBPFBrokerCommandName =
    AndroidPrivilegedOperation.bpfBrokerCommandName
let androidBPFMountCommandName =
    AndroidPrivilegedOperation.bpfMountCommandName
let androidCgroupDelegateCommandName =
    AndroidPrivilegedOperation.cgroupDelegateCommandName

struct AndroidBPFBrokerInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(
        helperExecutable: String,
        socket: String,
        rootUID: UInt32,
        rootGID: UInt32
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            helperExecutable,
            androidBPFBrokerCommandName,
            "--socket",
            socket,
            "--root-uid",
            String(rootUID),
            "--root-gid",
            String(rootGID),
        ]
    }
}
