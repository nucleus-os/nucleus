import ColliderCore
import ColliderRuntime
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
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
        case "adapter":
            try await assembleAdapter(Array(arguments.dropFirst()))
        case "control-adapters":
            try await assembleControlAdapters(Array(arguments.dropFirst()))
        case "control-payloads":
            try await materializeControlPayloads(Array(arguments.dropFirst()))
        case "payload":
            try await materializePayload(Array(arguments.dropFirst()))
        case "packages":
            try await assemblePackages(Array(arguments.dropFirst()))
        default:
            throw LinuxAssemblerFailure.invalidArguments
        }
    }

    private static func assembleControlAdapters(_ arguments: [String]) async throws {
        guard arguments.count == 7,
            let architecture = PlatformArchitecture(rawValue: arguments[4])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        var stages: [ActionStageObservation] = []
        for family in LinuxDistributionFamily.allCases {
            for package in LinuxNativePackageName.controlOnly {
                let root = FilePath(arguments[3]).appending(
                    "\(family.rawValue)/\(package.rawValue)")
                let observations = try await execute(
                    AssembleLinuxNativePackageAdapterAction(
                        publication: LinuxNativePackageAdapterPublication(
                            architecture: architecture,
                            family: family,
                            package: package,
                            runtimeArtifactRoot: FilePath(arguments[0]),
                            browser: BrowserPackageInputPublication(
                                target: ArtifactTarget(
                                    operatingSystem: .linux,
                                    architecture: architecture,
                                    abi: "glibc"),
                                distributionRoot: FilePath(arguments[1]),
                                packageInputRoot: FilePath(arguments[2])),
                            payloadRoot: root.appending(".payload-view"),
                            outputRoot: root,
                            assemblerExecutable: FilePath(arguments[5]))))
                stages += observations.actionStages
            }
        }
        try Data(JSONEncoder().encode(stages)).write(
            to: URL(fileURLWithPath: arguments[6]),
            options: .atomic)
    }

    private static func assembleAdapter(_ arguments: [String]) async throws {
        guard arguments.count == 10,
            let architecture = PlatformArchitecture(rawValue: arguments[5]),
            let family = LinuxDistributionFamily(rawValue: arguments[6]),
            let package = LinuxNativePackageName(rawValue: arguments[7])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        let observations = try await execute(
            AssembleLinuxNativePackageAdapterAction(
                publication: LinuxNativePackageAdapterPublication(
                    architecture: architecture,
                    family: family,
                    package: package,
                    runtimeArtifactRoot: FilePath(arguments[0]),
                    browser: BrowserPackageInputPublication(
                        target: ArtifactTarget(
                            operatingSystem: .linux,
                            architecture: architecture,
                            abi: "glibc"),
                        distributionRoot: FilePath(arguments[1]),
                        packageInputRoot: FilePath(arguments[2])),
                    payloadRoot: FilePath(arguments[3]),
                    outputRoot: FilePath(arguments[4]),
                    assemblerExecutable: FilePath(arguments[8]))))
        try Data(JSONEncoder().encode(observations.actionStages)).write(
            to: URL(fileURLWithPath: arguments[9]),
            options: .atomic)
    }

    private static func materializePayload(_ arguments: [String]) async throws {
        guard arguments.count == 8,
            let architecture = PlatformArchitecture(rawValue: arguments[4]),
            let package = LinuxNativePackageName(rawValue: arguments[5])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        let observations = try await execute(
            MaterializeLinuxNativePackagePayloadAction(
                publication: LinuxNativePackagePayloadPublication(
                    architecture: architecture,
                    runtimeArtifactRoot: FilePath(arguments[0]),
                    browser: BrowserPackageInputPublication(
                        target: ArtifactTarget(
                            operatingSystem: .linux,
                            architecture: architecture,
                            abi: "glibc"),
                        distributionRoot: FilePath(arguments[1]),
                        packageInputRoot: FilePath(arguments[2])),
                    androidPackageInputRoot:
                        arguments[6] == "-" ? nil : FilePath(arguments[6]),
                    outputRoot: FilePath(arguments[3]),
                    package: package)))
        try Data(JSONEncoder().encode(observations.actionStages)).write(
            to: URL(fileURLWithPath: arguments[7]),
            options: .atomic)
    }

    private static func materializeControlPayloads(_ arguments: [String]) async throws {
        guard arguments.count == 6,
            let architecture = PlatformArchitecture(rawValue: arguments[4])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        var stages: [ActionStageObservation] = []
        for package in LinuxNativePackageName.controlOnly {
            let observations = try await execute(
                MaterializeLinuxNativePackagePayloadAction(
                    publication: LinuxNativePackagePayloadPublication(
                        architecture: architecture,
                        runtimeArtifactRoot: FilePath(arguments[0]),
                        browser: BrowserPackageInputPublication(
                            target: ArtifactTarget(
                                operatingSystem: .linux,
                                architecture: architecture,
                                abi: "glibc"),
                            distributionRoot: FilePath(arguments[1]),
                            packageInputRoot: FilePath(arguments[2])),
                        outputRoot: FilePath(arguments[3]).appending(
                            package.rawValue),
                        package: package)))
            stages += observations.actionStages
        }
        try Data(JSONEncoder().encode(stages)).write(
            to: URL(fileURLWithPath: arguments[5]),
            options: .atomic)
    }

    private static func assemblePackages(_ arguments: [String]) async throws {
        guard arguments.count == 13,
            let architecture = PlatformArchitecture(rawValue: arguments[6]),
            let runnerOperatingSystem = PlatformOperatingSystem(rawValue: arguments[8]),
            let runnerArchitecture = PlatformArchitecture(rawValue: arguments[9])
        else {
            throw LinuxAssemblerFailure.invalidArguments
        }
        let observations = try await execute(
            AssembleLinuxNativePackagesAction(
                publication: LinuxNativePackagePublication(
                    architecture: architecture,
                    sourceSnapshot: FilePath(arguments[0]),
                    runtimeArtifactRoot: FilePath(arguments[1]),
                    browser: BrowserPackageInputPublication(
                        target: ArtifactTarget(
                            operatingSystem: .linux,
                            architecture: architecture,
                            abi: "glibc"),
                        distributionRoot: FilePath(arguments[2]),
                        packageInputRoot: FilePath(arguments[3])),
                    adapterRoot: FilePath(arguments[4]),
                    outputRoot: FilePath(arguments[5]),
                    assemblerExecutable: FilePath(arguments[7]),
                    builderImageID: FilePath(arguments[10]),
                    producingTask: TaskID(rawValue: arguments[11]),
                    producerRunner: RunnerPlatform(
                        operatingSystem: runnerOperatingSystem,
                        architecture: runnerArchitecture),
                    environment: ProcessInfo.processInfo.environment)))
        try Data(JSONEncoder().encode(observations.actionStages)).write(
            to: URL(fileURLWithPath: arguments[12]),
            options: .atomic)
    }

    private static func execute<Action: ColliderAction>(
        _ action: Action
    ) async throws -> TaskExecutionObservations {
        let runtime = ColliderRuntime()
        do {
            let observations = try await runtime.execute(action)
            await runtime.shutdown()
            return observations
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
            "usage: nucleus-linux-assembler packages <arguments...>"
        case .linuxRequired:
            "nucleus-linux-assembler requires Linux"
        }
    }
}
