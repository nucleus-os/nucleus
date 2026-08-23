import ColliderCore
import ColliderRuntime
import Foundation
import ShellColliderRecipe
import SystemPackage

#if os(Linux)
@main
struct NucleusLinuxRuntimePublisher {
    static func main() async {
        do {
            try await run()
        } catch {
            failLinuxRuntimePublisher(error)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 9,
            let rollbackGenerationCount = UInt32(arguments[4]),
            let targetArchitecture = PlatformArchitecture(rawValue: arguments[7])
        else {
            throw LinuxRuntimePublisherFailure.invalidArguments
        }
        let targetLibraryRoots = arguments[8]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { FilePath(String($0)) }
        let runtime = ColliderRuntime()
        do {
            _ = try await runtime.execute(
                PublishRuntimeGenerationAction(
                    products: FilePath(arguments[0]),
                    prefix: FilePath(arguments[1]),
                    generationsRoot: FilePath(arguments[2]),
                    packageManifestsRoot: FilePath(arguments[3]),
                    rollbackGenerationCount: rollbackGenerationCount,
                    sessionPackage: FilePath(arguments[5]),
                    buildMetadata: arguments[6],
                    targetArchitecture: targetArchitecture,
                    targetLibraryRoots: targetLibraryRoots,
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
struct NucleusLinuxRuntimePublisher {
    static func main() {
        failLinuxRuntimePublisher(LinuxRuntimePublisherFailure.linuxRequired)
    }
}
#endif

private func failLinuxRuntimePublisher(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private enum LinuxRuntimePublisherFailure: Error, CustomStringConvertible {
    case invalidArguments
    case linuxRequired

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: nucleus-linux-runtime-publisher <arguments...>"
        case .linuxRequired:
            "nucleus-linux-runtime-publisher requires Linux"
        }
    }
}
