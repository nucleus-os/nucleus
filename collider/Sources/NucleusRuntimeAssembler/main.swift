import ColliderRuntime
import Foundation
import ShellColliderRecipe
import SystemPackage

#if os(Linux)
@main
struct NucleusRuntimeAssembler {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 7 else {
            throw RuntimeAssemblerFailure.invalidArguments
        }

        let runtime = ColliderRuntime()
        do {
            try await runtime.execute(
                InstallRuntimeAction(
                    products: FilePath(arguments[0]),
                    prefix: FilePath(arguments[1]),
                    generationsRoot: FilePath(arguments[2]),
                    packageManifestsRoot: FilePath(arguments[3]),
                    sessionPackage: FilePath(arguments[4]),
                    kernelContract: FilePath(arguments[5]),
                    trustKey: nil,
                    buildMetadata: arguments[6],
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
            + "<package-manifests> <session-package> <kernel-contract> <metadata>"
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
