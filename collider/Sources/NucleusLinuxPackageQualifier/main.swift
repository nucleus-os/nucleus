import ColliderCore
import ColliderRuntime
import Foundation
import LinuxColliderRecipe
import ShellColliderRecipe
import SystemPackage

#if os(Linux)
@main
struct NucleusLinuxPackageQualifier {
    static func main() async {
        do {
            try await run()
        } catch {
            failLinuxPackageQualifier(error)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 7,
            let family = LinuxDistributionFamily(rawValue: arguments[0]),
            let architecture = PlatformArchitecture(rawValue: arguments[1])
        else {
            throw LinuxPackageQualifierFailure.invalidArguments
        }
        let runtime = ColliderRuntime()
        do {
            try await runtime.execute(
                QualifyLinuxNativePackageLifecycleAction(
                    family: family,
                    architecture: architecture,
                    packagePublicationRoot: FilePath(arguments[2]),
                    productStoreRoot: FilePath(arguments[3]),
                    qualificationRoot: FilePath(arguments[4]),
                    assemblerExecutable: FilePath(arguments[5]),
                    builderImageID: FilePath(arguments[6]),
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
struct NucleusLinuxPackageQualifier {
    static func main() {
        failLinuxPackageQualifier(LinuxPackageQualifierFailure.linuxRequired)
    }
}
#endif

private func failLinuxPackageQualifier(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

private enum LinuxPackageQualifierFailure: Error, CustomStringConvertible {
    case invalidArguments
    case linuxRequired

    var description: String {
        switch self {
        case .invalidArguments:
            "usage: nucleus-linux-package-qualifier <debian|rpm|arch> "
                + "<arm64|x86_64> <package-root> <product-store> "
                + "<qualification-root> <assembler> <builder-image-id>"
        case .linuxRequired:
            "nucleus-linux-package-qualifier requires Linux"
        }
    }
}
