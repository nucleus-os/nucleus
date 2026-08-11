import ColliderRuntime
import Foundation
import ShellColliderRecipe
import SystemPackage

#if os(Linux)
@main
struct NucleusRuntimeAssembler {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 8,
            let rollbackGenerationCount = UInt32(arguments[4])
        else {
            throw RuntimeAssemblerFailure.invalidArguments
        }

        let runtime = ColliderRuntime()
        do {
            try await runtime.execute(
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
                    environment: ProcessInfo.processInfo.environment))
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }
}

private enum RuntimeAssemblerFailure: Error, CustomStringConvertible {
    case invalidArguments

    var description: String {
        "usage: nucleus-runtime-assembler <products> <current> <generations> "
            + "<package-manifests> <rollback-generations> <session-package> "
            + "<kernel-contract> <metadata>"
    }
}
#else
@main
struct NucleusRuntimeAssembler {
    static func main() throws {
        throw RuntimeAssemblerFailure.linuxRequired
    }
}

private enum RuntimeAssemblerFailure: Error, CustomStringConvertible {
    case linuxRequired

    var description: String {
        "nucleus-runtime-assembler requires Linux"
    }
}
#endif
