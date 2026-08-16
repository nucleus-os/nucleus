import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import LinuxColliderRecipe
import ShellColliderRecipe
import SystemPackage

#if os(Linux)
@main
struct NucleusLinuxAssembler {
    static func main() async {
        do {
            try await run()
        } catch {
            failLinuxAssembler(error)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let operation = arguments.first else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        switch operation {
        case "runtime":
            try await assembleRuntime(Array(arguments.dropFirst()))
        case "packages":
            try await assemblePackages(Array(arguments.dropFirst()))
        default:
            throw LinuxAssemblerFailure.invalidArguments
        }
    }

    private static func assembleRuntime(_ arguments: [String]) async throws {
        guard arguments.count == 9,
            let rollbackGenerationCount = UInt32(arguments[4]),
            let targetArchitecture = PlatformArchitecture(rawValue: arguments[8])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        try await execute(
            PublishRuntimeGenerationAction(
                products: FilePath(arguments[0]),
                prefix: FilePath(arguments[1]),
                generationsRoot: FilePath(arguments[2]),
                packageManifestsRoot: FilePath(arguments[3]),
                rollbackGenerationCount: rollbackGenerationCount,
                sessionPackage: FilePath(arguments[5]),
                kernelContract: FilePath(arguments[6]),
                trustKey: nil,
                buildMetadata: arguments[7],
                targetArchitecture: targetArchitecture,
                environment: ProcessInfo.processInfo.environment))
    }

    private static func assemblePackages(_ arguments: [String]) async throws {
        guard arguments.count == 11,
            let architecture = PlatformArchitecture(rawValue: arguments[6]),
            let runnerOperatingSystem = PlatformOperatingSystem(rawValue: arguments[8]),
            let runnerArchitecture = PlatformArchitecture(rawValue: arguments[9])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        try await execute(
            AssembleLinuxNativePackagesAction(
                publication: LinuxNativePackagePublication(
                    architecture: architecture,
                    sourceSnapshot: FilePath(arguments[0]),
                    runtimeArtifactRoot: FilePath(arguments[1]),
                    browser: BrowserPackageInputPublication(
                        target: ChromiumLinuxTarget(architecture: architecture),
                        distributionRoot: FilePath(arguments[2]),
                        packageInputRoot: FilePath(arguments[3])),
                    outputRoot: FilePath(arguments[4]),
                    productStoreRoot: FilePath(arguments[5]),
                    assemblerExecutable: FilePath(arguments[7]),
                    builderImageID: FilePath(arguments[10]),
                    producerRunner: RunnerPlatform(
                        operatingSystem: runnerOperatingSystem,
                        architecture: runnerArchitecture),
                    environment: ProcessInfo.processInfo.environment)))
    }

    private static func execute<Action: ColliderAction>(_ action: Action) async throws {
        let runtime = ColliderRuntime()
        do {
            try await runtime.execute(action)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }
}
#else
@main
struct NucleusLinuxAssembler {
    static func main() {
        failLinuxAssembler(LinuxAssemblerFailure.linuxRequired)
    }
}
#endif

private func failLinuxAssembler(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private enum LinuxAssemblerFailure: Error, CustomStringConvertible {
    case invalidArguments
    case linuxRequired

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: nucleus-linux-assembler <runtime|packages> <arguments...>"
        case .linuxRequired:
            "nucleus-linux-assembler requires Linux"
        }
    }
}
