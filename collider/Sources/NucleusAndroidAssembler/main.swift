import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

#if os(Linux)
import AndroidRuntimeColliderRecipe

@main
struct NucleusAndroidAssembler {
    static func main() async {
        do {
            try await run()
        } catch {
            failAndroidAssembler(error)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw AndroidAssemblerFailure.invalidArguments
        }
        arguments.removeFirst()
        let action: any ColliderAction =
            switch command {
            case "package-input": try packageInput(arguments)
            case "signing-identity": try signingIdentity(arguments)
            default: throw AndroidAssemblerFailure.invalidArguments
            }
        let runtime = ColliderRuntime()
        do {
            _ = try await runtime.execute(action)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private static func packageInput(
        _ arguments: [String]
    ) throws -> any ColliderAction {
        guard arguments.count == 9,
            let architecture = PlatformArchitecture(rawValue: arguments[7])
        else {
            throw AndroidAssemblerFailure.invalidArguments
        }
        let targetLibraryRoots = arguments[8]
            .split(separator: ":")
            .map { FilePath(String($0)) }
        return MaterializeAndroidPackageInputAction(
            runtimeProducts: FilePath(arguments[0]),
            runtimeScratch: FilePath(arguments[4]),
            aospGeneration: FilePath(arguments[1]),
            aospSigningKey: FilePath(arguments[2]),
            architecture: architecture,
            targetLibraryRoots: targetLibraryRoots,
            output: FilePath(arguments[3]),
            appArmorPolicy: FilePath(arguments[5]),
            seccompPolicy: FilePath(arguments[6]),
            environment: ProcessInfo.processInfo.environment)
    }

    private static func signingIdentity(
        _ arguments: [String]
    ) throws -> any ColliderAction {
        guard arguments.count == 2 else {
            throw AndroidAssemblerFailure.invalidArguments
        }
        return PrepareAOSPSigningIdentityAction(
            preparation: AOSPSigningIdentityPreparation(
                destination: FilePath(arguments[0]),
                subject: arguments[1],
                environment: ProcessInfo.processInfo.environment))
    }
}
#else
@main
struct NucleusAndroidAssembler {
    static func main() {
        failAndroidAssembler(AndroidAssemblerFailure.linuxRequired)
    }
}
#endif

private func failAndroidAssembler(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private enum AndroidAssemblerFailure: Error, CustomStringConvertible {
    case invalidArguments
    case linuxRequired

    var description: String {
        switch self {
        case .invalidArguments:
            "expected 'package-input' with runtime products, AOSP generation, "
                + "signing key, output, scratch, AppArmor policy, seccomp "
                + "policy, architecture, and target library roots, or "
                + "'signing-identity' with a destination and subject"
        case .linuxRequired:
            "Android products are assembled on Linux"
        }
    }
}
