import Foundation
import Glibc
import NucleusAndroidRuntimeCore

do {
    try AndroidRuntimePrivilegedCommand.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment)
} catch {
    FileHandle.standardError.write(
        Data("nucleus-android-runtime-privileged: \(error)\n".utf8))
    exit(1)
}
