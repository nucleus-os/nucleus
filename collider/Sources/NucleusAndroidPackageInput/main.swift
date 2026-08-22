import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

#if os(Linux)
import AndroidRuntimeColliderRecipe

@main
struct NucleusAndroidPackageInput {
    static func main() async {
        do {
            try await run()
        } catch {
            failAndroidPackageInput(error)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 8,
            let architecture = PlatformArchitecture(rawValue: arguments[7])
        else {
            throw AndroidPackageInputToolFailure.invalidArguments
        }
        let runtime = ColliderRuntime()
        do {
            _ = try await runtime.execute(
                MaterializeAndroidPackageInputAction(
                    runtimeProducts: FilePath(arguments[0]),
                    runtimeRoot: nil,
                    runtimeScratch: FilePath(arguments[4]),
                    aospGeneration: FilePath(arguments[1]),
                    aospSigningKey: FilePath(arguments[2]),
                    architecture: architecture,
                    output: FilePath(arguments[3]),
                    appArmorPolicy: FilePath(arguments[5]),
                    seccompPolicy: FilePath(arguments[6]),
                    environment: ProcessInfo.processInfo.environment))
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }
}
#else
@main
struct NucleusAndroidPackageInput {
    static func main() {
        failAndroidPackageInput(AndroidPackageInputToolFailure.linuxRequired)
    }
}
#endif

private func failAndroidPackageInput(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private enum AndroidPackageInputToolFailure: Error, CustomStringConvertible {
    case invalidArguments
    case linuxRequired

    var description: String {
        switch self {
        case .invalidArguments:
            "expected runtime products, AOSP generation, signing key, output, "
                + "scratch, AppArmor policy, seccomp policy, and architecture"
        case .linuxRequired:
            "Android package inputs are materialized on Linux"
        }
    }
}
