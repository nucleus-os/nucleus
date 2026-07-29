import ColliderAndroidPrivileged
import ColliderRuntime
import Foundation

let androidApexMountCommandName =
    AndroidPrivilegedOperation.apexMountCommandName

struct AndroidApexMountInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(
        helperExecutable: String,
        request: AndroidApexMountRequest
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            helperExecutable,
            androidApexMountCommandName,
            "--root-file-system",
            request.rootFileSystem,
            "--source",
            request.source,
            "--target",
            request.target,
            "--payload-file-system",
            request.payloadFileSystem.rawValue,
            "--payload-offset",
            String(request.payloadOffset),
        ]
    }
}

func currentColliderAndroidPrivilegedExecutable() throws -> String {
#if os(Linux)
    let colliderPath = try FileManager.default.destinationOfSymbolicLink(
        atPath: "/proc/self/exe")
#else
    let argument = CommandLine.arguments[0]
    let colliderPath = URL(
        fileURLWithPath: argument,
        relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
    ).standardizedFileURL.path
#endif
    let path = URL(fileURLWithPath: colliderPath)
        .deletingLastPathComponent()
        .appendingPathComponent("collider-android-privileged")
        .path
    guard path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: path)
    else {
        throw WorkspaceFailure.message(
            "Collider Android privileged helper is missing next to the "
                + "running Collider executable; run ./collider-setup.sh "
                + "--repair")
    }
    return path
}
