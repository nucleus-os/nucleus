import ColliderCore
import Foundation
import SystemPackage

public struct SwiftTargetSDKStoragePaths: Equatable, Sendable {
    public let cacheRoot: FilePath
    public let artifactRoot: FilePath
    public let downloadRoot: FilePath
    public let generatorScratch: FilePath
    public let runtimeBuilderImageID: FilePath
    public let runtimeCompilerCache: FilePath
    public let runtimeBuildRoot: FilePath
    public let rebuildLock: FilePath

    public init(cacheRoot: FilePath) {
        self.cacheRoot = cacheRoot
        artifactRoot = cacheRoot.appending("nucleus/swift-target-sdks")
        downloadRoot = cacheRoot.appending("nucleus/downloads/swift-target-sdks")
        generatorScratch = cacheRoot.appending("nucleus/build/swift-sdk-generator")
        runtimeBuilderImageID = cacheRoot.appending(
            "nucleus/build-containers/swift-runtime/image-id")
        runtimeCompilerCache = cacheRoot.appending("nucleus/ccache/swift-runtime")
        runtimeBuildRoot = cacheRoot.appending("nucleus/build/swift-target-runtime")
        rebuildLock = artifactRoot.appending("rebuild.lock")
    }
}

public func swiftTargetSDKTaskEnvironment(
    _ environment: [String: String],
    runtimeSourceID: String
) -> [String: String] {
    var environment = environment
    environment["NUCLEUS_SWIFT_SOURCE_ID"] = runtimeSourceID
    return environment
}

public struct SwiftTargetSDKInputs: Codable, Equatable, Sendable {
    public enum LinuxArchitecture: String, Codable, CaseIterable, Hashable, Sendable {
        case arm64
        case amd64 = "x86_64"

        public var triple: String {
            switch self {
            case .arm64: "aarch64-unknown-linux-gnu"
            case .amd64: "x86_64-unknown-linux-gnu"
            }
        }

        public var swiftBuildArchitecture: String {
            switch self {
            case .arm64: "aarch64"
            case .amd64: "x86_64"
            }
        }

        public var debianArchitecture: String {
            switch self {
            case .arm64: "arm64"
            case .amd64: "amd64"
            }
        }

        public var gnuArchitecture: String {
            switch self {
            case .arm64: "aarch64-linux-gnu"
            case .amd64: "x86_64-linux-gnu"
            }
        }

        public var artifactTarget: ArtifactTarget {
            switch self {
            case .arm64: .linuxARM64
            case .amd64: .linuxX86_64
            }
        }
    }

    public struct Input: Codable, Equatable, Sendable {
        public let maximumResponseSize: Int64
        public let sha256: String
        public let url: String
    }

    public struct UbuntuPackage: Codable, Equatable, Sendable {
        public let sha256: String
        public let url: String
    }

    public struct LinuxTarget: Codable, Equatable, Sendable {
        public let architecture: LinuxArchitecture
        public let runtimeUbuntuPackages: [UbuntuPackage]
        public let sdkUbuntuPackages: [UbuntuPackage]

        public init(
            architecture: LinuxArchitecture,
            runtimeUbuntuPackages: [UbuntuPackage],
            sdkUbuntuPackages: [UbuntuPackage]
        ) {
            self.architecture = architecture
            self.runtimeUbuntuPackages = runtimeUbuntuPackages
            self.sdkUbuntuPackages = sdkUbuntuPackages
        }

        public var allUbuntuPackages: [UbuntuPackage] {
            runtimeUbuntuPackages + sdkUbuntuPackages
        }
    }

    public struct Artifacts: Codable, Equatable, Sendable {
        public let androidSDK: Input
        public let macOSHostPackage: Input
    }

    public let artifacts: Artifacts
    public let linuxTargets: [LinuxTarget]
    public let snapshot: String

    public var androidBundleID: String { "\(snapshot)_android" }
    public var linuxBundleID: String { "nucleus-swift-6.4-linux" }

    public static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct SwiftLinuxTargetBuildConfiguration: Sendable {
    public let target: SwiftTargetSDKInputs.LinuxTarget
    public let runtimeBuildWorkspace: FilePath
    public let runtimeCompilerCache: FilePath
    public let runtimeInstall: FilePath
    public let sysroot: FilePath

    public init(
        target: SwiftTargetSDKInputs.LinuxTarget,
        runtimeBuildWorkspace: FilePath,
        runtimeCompilerCache: FilePath,
        runtimeInstall: FilePath,
        sysroot: FilePath
    ) {
        self.target = target
        self.runtimeBuildWorkspace = runtimeBuildWorkspace
        self.runtimeCompilerCache = runtimeCompilerCache
        self.runtimeInstall = runtimeInstall
        self.sysroot = sysroot
    }
}

public struct SwiftTargetSDKGenerationConfiguration: RecipeConfiguration {
    public let inputs: SwiftTargetSDKInputs
    public let inputsFile: FilePath
    public let androidAPILevel: UInt32
    public let downloadRoot: FilePath
    public let generatorSource: FilePath
    public let generatorScratch: FilePath
    public let sourceWorkspace: FilePath
    public let sourceID: String
    public let runtimeBuilderContext: FilePath
    public let runtimeBuilderImageID: FilePath
    public let linuxTargets: [SwiftLinuxTargetBuildConfiguration]
    public let sysrootPreparer: FilePath
    public let candidate: FilePath
    public let generation: FilePath
    public let active: FilePath
    public let ndkRoot: FilePath
    public let validationFixture: FilePath
    public let validator: FilePath
    public let swiftExecutable: FilePath
    public let sdkDiscoveryRoot: FilePath
    public let displacedRoot: FilePath
    public let rebuildLock: FilePath
    public let environment: [String: String]

    public init(
        inputs: SwiftTargetSDKInputs,
        inputsFile: FilePath,
        androidAPILevel: UInt32,
        downloadRoot: FilePath,
        generatorSource: FilePath,
        generatorScratch: FilePath,
        sourceWorkspace: FilePath,
        sourceID: String,
        runtimeBuilderContext: FilePath,
        runtimeBuilderImageID: FilePath,
        linuxTargets: [SwiftLinuxTargetBuildConfiguration],
        sysrootPreparer: FilePath,
        candidate: FilePath,
        generation: FilePath,
        active: FilePath,
        ndkRoot: FilePath,
        validationFixture: FilePath,
        validator: FilePath,
        swiftExecutable: FilePath,
        sdkDiscoveryRoot: FilePath,
        displacedRoot: FilePath,
        rebuildLock: FilePath,
        environment: [String: String]
    ) {
        self.inputs = inputs
        self.inputsFile = inputsFile
        self.androidAPILevel = androidAPILevel
        self.downloadRoot = downloadRoot
        self.generatorSource = generatorSource
        self.generatorScratch = generatorScratch
        self.sourceWorkspace = sourceWorkspace
        self.sourceID = sourceID
        self.runtimeBuilderContext = runtimeBuilderContext
        self.runtimeBuilderImageID = runtimeBuilderImageID
        self.linuxTargets = linuxTargets
        self.sysrootPreparer = sysrootPreparer
        self.candidate = candidate
        self.generation = generation
        self.active = active
        self.ndkRoot = ndkRoot
        self.validationFixture = validationFixture
        self.validator = validator
        self.swiftExecutable = swiftExecutable
        self.sdkDiscoveryRoot = sdkDiscoveryRoot
        self.displacedRoot = displacedRoot
        self.rebuildLock = rebuildLock
        self.environment = environment
    }
}

public struct SwiftTargetSDKTaskSet: Sendable {
    public let tasks: [TaskDeclaration]
    public let selected: [TaskID]
    public let activeSDK: ArtifactReference<PathArtifact>
}

public enum SwiftTargetSDKRecipeFailure: Error, CustomStringConvertible, Sendable {
    case invalidInput(String)

    public var description: String {
        switch self {
        case .invalidInput(let message): message
        }
    }
}

public enum SwiftTargetSDKColliderRecipe: ColliderComponent {
    package struct PreparedComponent: Sendable {
        package let component: ComponentDefinition
        package let activeSDK: ArtifactReference<PathArtifact>
    }

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "swift-sdk"),
        canonicalName: "swift-sdk",
        directoryName: "swift-sdk")
    private static let component = descriptor.id

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        try prepare(in: context).component
    }

    package static func prepare(
        in context: RecipeContext
    ) throws -> PreparedComponent {
        let configuration: SwiftTargetSDKGenerationConfiguration =
            try context.configuration(for: descriptor.id)
        return try prepare(configuration)
    }

    package static func prepare(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> PreparedComponent {
        let taskSet = try generation(configuration)
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: taskSet.tasks,
            entrypoints: [
                ComponentEntrypoint(
                    id: .build,
                    roots: Set(taskSet.selected))
            ])
        return PreparedComponent(
            component: component,
            activeSDK: taskSet.activeSDK)
    }

    public static func generation(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> SwiftTargetSDKTaskSet {
        try validate(configuration.inputs)
        guard configuration.androidAPILevel >= 24 else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "Swift Android SDK API level must be at least 24")
        }
        guard
            configuration.linuxTargets.map(\.target) == configuration.inputs.linuxTargets
        else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "Linux build paths do not match the declared target order")
        }

        let downloads = try downloadTasks(configuration)
        let runtimeBuilder = try runtimeBuilderTask(configuration)
        let sysroots = try configuration.linuxTargets.map { target in
            try linuxSysrootTask(
                configuration,
                target: target,
                downloads: try linuxDownloads(
                    for: target.target.architecture,
                    in: downloads))
        }
        let runtimes = try zip(configuration.linuxTargets, sysroots).map { target, sysroot in
            try linuxRuntimeTask(
                configuration,
                target: target,
                builder: runtimeBuilder,
                sysroot: sysroot.artifact)
        }
        let generator = try generatorTask(configuration)
        let assembly = try assemblyTask(
            configuration,
            downloads: downloads,
            generator: generator,
            runtimes: runtimes)
        let validation = try validationTask(configuration, assembly: assembly)
        let activation = try activationTask(configuration, validation: validation)
        let discoveries = try discoveryTasks(configuration, activation: activation)

        let tasks =
            downloads.tasks
            + [runtimeBuilder.task] + sysroots.map(\.task) + runtimes.map(\.task)
            + [generator.task, assembly.task, validation.task, activation.task]
            + discoveries.map(\.task)
        return SwiftTargetSDKTaskSet(
            tasks: tasks.map {
                $0.addingLocks([.shared(configuration.rebuildLock)])
            },
            selected: discoveries.map(\.task.id),
            activeSDK: activation.activeSDK)
    }

    private struct Downloads {
        let host: DownloadArtifact
        let android: DownloadArtifact
        let linux: [LinuxDownloads]

        var tasks: [TaskDeclaration] {
            [host.task, android.task] + linux.flatMap(\.tasks)
        }

        var artifacts: [ArtifactReference<FileArtifact>] {
            [host.artifact, android.artifact] + linux.flatMap(\.allPackages)
        }
    }

    private struct DownloadArtifact {
        let task: TaskDeclaration
        let artifact: ArtifactReference<FileArtifact>
    }

    private struct SysrootArtifact {
        let task: TaskDeclaration
        let artifact: ArtifactReference<DirectoryArtifact>
    }

    private struct RuntimeArtifact {
        let task: TaskDeclaration
        let install: ArtifactReference<DirectoryArtifact>
    }

    private struct RuntimeBuilderArtifact {
        let task: TaskDeclaration
        let image: ArtifactReference<FileArtifact>
    }

    private struct GeneratorArtifact {
        let task: TaskDeclaration
        let executable: ArtifactReference<ExecutableArtifact>
    }

    private struct AssemblyArtifacts {
        let task: TaskDeclaration
        let hostSwift: ArtifactReference<ExecutableArtifact>
        let linuxSDK: ArtifactReference<DirectoryArtifact>
        let androidSDK: ArtifactReference<DirectoryArtifact>
    }

    private struct ValidationArtifacts {
        let task: TaskDeclaration
        let executables: [ArtifactReference<ExecutableArtifact>]
    }

    private struct ActivationArtifact {
        let task: TaskDeclaration
        let generationMarker: ArtifactReference<FileArtifact>
        let activeSDK: ArtifactReference<PathArtifact>
    }

    private struct DiscoveryArtifact {
        let task: TaskDeclaration
        let link: ArtifactReference<PathArtifact>
    }

    private struct LinuxDownloads {
        let architecture: SwiftTargetSDKInputs.LinuxArchitecture
        let runtimePackages: [DownloadArtifact]
        let sdkPackages: [DownloadArtifact]

        var tasks: [TaskDeclaration] {
            (runtimePackages + sdkPackages).map(\.task)
        }

        var allPackages: [ArtifactReference<FileArtifact>] {
            (runtimePackages + sdkPackages).map(\.artifact)
        }
    }

    private static func validate(_ inputs: SwiftTargetSDKInputs) throws {
        guard !inputs.snapshot.isEmpty,
            inputs.linuxTargets.map(\.architecture).sorted(by: { $0.rawValue < $1.rawValue })
                == SwiftTargetSDKInputs.LinuxArchitecture.allCases.sorted(by: {
                    $0.rawValue < $1.rawValue
                }),
            inputs.linuxTargets.allSatisfy({
                !$0.runtimeUbuntuPackages.isEmpty && !$0.sdkUbuntuPackages.isEmpty
            })
        else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "Swift target SDK inputs are incomplete")
        }
    }

    private static func downloadTasks(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> Downloads {
        let host = try downloadTask(
            id: "swift-sdk.download-host",
            input: configuration.inputs.artifacts.macOSHostPackage,
            destination: configuration.downloadRoot.appending("host-macos.pkg"))
        let android = try downloadTask(
            id: "swift-sdk.download-android-sdk",
            input: configuration.inputs.artifacts.androidSDK,
            destination: configuration.downloadRoot.appending("android-sdk.tar.gz"))
        let linux = try configuration.inputs.linuxTargets.map { target in
            func tasks(
                for packages: [SwiftTargetSDKInputs.UbuntuPackage],
                role: String
            ) throws -> [DownloadArtifact] {
                try packages.enumerated().map { index, package in
                    let name = try fileName(from: package.url)
                    return try downloadTask(
                        id:
                            "swift-sdk.download-ubuntu-\(target.architecture.rawValue)-\(role)-\(index)",
                        input: SwiftTargetSDKInputs.Input(
                            maximumResponseSize: 32 * 1_024 * 1_024,
                            sha256: package.sha256,
                            url: package.url),
                        destination: configuration.downloadRoot.appending(
                            "ubuntu/\(target.architecture.rawValue)/\(name)"))
                }
            }
            let runtimeTasks = try tasks(for: target.runtimeUbuntuPackages, role: "runtime")
            let sdkTasks = try tasks(for: target.sdkUbuntuPackages, role: "sdk")
            return LinuxDownloads(
                architecture: target.architecture,
                runtimePackages: runtimeTasks,
                sdkPackages: sdkTasks)
        }
        return Downloads(
            host: host,
            android: android,
            linux: linux)
    }

    private static func downloadTask(
        id: String,
        input: SwiftTargetSDKInputs.Input,
        destination: FilePath
    ) throws -> DownloadArtifact {
        guard let url = URL(string: input.url),
            let digest = ArtifactDigest(sha256Hex: input.sha256)
        else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "invalid download input for \(id)")
        }
        let specification = try DownloadSpec(
            url: url,
            permittedRedirectOrigins: [
                "https://download.swift.org",
                "https://gb.archive.ubuntu.com",
                "https://ports.ubuntu.com",
                "https://security.ubuntu.com",
                "https://swift.org",
            ],
            expectedDigest: digest,
            maximumResponseSize: input.maximumResponseSize,
            acceptedMediaTypes: [
                "application/gzip",
                "application/octet-stream",
                "application/vnd.debian.binary-package",
                "application/vnd.apple.installer+xml",
                "application/x-apple-diskimage",
                "application/x-debian-package",
                "application/x-gzip",
                "application/x-xar",
            ],
            requestTimeoutSeconds: 300,
            inactivityTimeoutSeconds: 60,
            maximumRedirects: 5,
            maximumRetries: 2,
            resumption: .validatorRequired)
        var builder = TaskBuilder(
            id: TaskID(rawValue: id),
            component: component)
        let artifact: ArtifactReference<FileArtifact> = try builder.output(
            "download",
            path: destination,
            validation: .regularFile)
        let task = builder.build(
            locks: [.checkout("swift-target-sdk-downloads")],
            action:
                try AnyColliderAction(
                    DownloadSwiftTargetSDKInputAction(
                        specification: specification,
                        destination: destination)))
        return DownloadArtifact(task: task, artifact: artifact)
    }

    private static func runtimeBuilderTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> RuntimeBuilderArtifact {
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.prepare-linux-runtime-builder"),
            component: component)
        let image: ArtifactReference<FileArtifact> = try builder.output(
            "image-id",
            path: configuration.runtimeBuilderImageID,
            validation: .regularFile)
        let task = builder.build(
            inputs: [.tree(configuration.runtimeBuilderContext)],
            locks: [.checkout("swift-linux-runtime-builder-image")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareSwiftRuntimeBuilderImageAction(
                        preparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: configuration.runtimeBuilderContext,
                            containerFile: configuration.runtimeBuilderContext.appending(
                                "Containerfile"),
                            imageID: configuration.runtimeBuilderImageID,
                            imageName: "localhost/nucleus-swift-runtime-build",
                            environment: configuration.environment))))
        return RuntimeBuilderArtifact(task: task, image: image)
    }

    private static func linuxSysrootTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        target: SwiftLinuxTargetBuildConfiguration,
        downloads: LinuxDownloads
    ) throws -> SysrootArtifact {
        let architecture = target.target.architecture
        var builder = TaskBuilder(
            id: TaskID(
                rawValue:
                    "swift-sdk.prepare-linux-\(architecture.rawValue)-libcxx-sysroot"),
            component: component)
        for package in downloads.runtimePackages {
            builder.consume(package.artifact)
        }
        let artifact: ArtifactReference<DirectoryArtifact> = try builder.output(
            "sysroot",
            path: target.sysroot,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [.file(configuration.sysrootPreparer)],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareLinuxSysrootAction(
                        preparer: configuration.sysrootPreparer,
                        sysroot: target.sysroot,
                        architecture: architecture.gnuArchitecture,
                        packages: downloads.runtimePackages.map(\.artifact.path),
                        environment: configuration.environment)))
        return SysrootArtifact(task: task, artifact: artifact)
    }

    private static func linuxRuntimeTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        target: SwiftLinuxTargetBuildConfiguration,
        builder: RuntimeBuilderArtifact,
        sysroot: ArtifactReference<DirectoryArtifact>
    ) throws -> RuntimeArtifact {
        let architecture = target.target.architecture
        let runtimeLibrary = target.runtimeInstall.appending(
            "usr/lib/swift/linux/libswiftCore.so")
        let swiftTestingModule = target.runtimeInstall.appending(
            "usr/lib/swift/linux/Testing.swiftmodule/\(architecture.triple).swiftinterface")
        let swiftTestingLibrary = target.runtimeInstall.appending(
            "usr/lib/swift/linux/libTesting.so")
        let mounts = [
            OCIMount(
                source: configuration.sourceWorkspace,
                target: "/src",
                access: .readOnly),
            OCIMount(
                source: configuration.inputsFile.removingLastComponent(),
                target: "/recipe",
                access: .readOnly),
            OCIMount(
                source: target.runtimeBuildWorkspace,
                target: "/build",
                access: .readWrite),
            OCIMount(
                source: target.runtimeCompilerCache,
                target: "/ccache",
                access: .readWrite),
            OCIMount(
                source: target.sysroot,
                target: "/target-sysroot",
                access: .readOnly),
            OCIMount(
                source: target.runtimeInstall,
                target: "/output",
                access: .readWrite),
        ]
        var containerEnvironment = [
            "CCACHE_BASEDIR": "/",
            "CCACHE_DIR": "/ccache",
            "NUCLEUS_TARGET_ARCHITECTURE": architecture.swiftBuildArchitecture,
            "NUCLEUS_TARGET_GNU_ARCHITECTURE": architecture.gnuArchitecture,
            "NUCLEUS_TARGET_TRIPLE": architecture.triple,
        ]
        if let jobs = configuration.environment["NUCLEUS_BUILD_JOBS"],
            !jobs.isEmpty
        {
            containerEnvironment["NUCLEUS_BUILD_JOBS"] = jobs
        }
        var taskBuilder = TaskBuilder(
            id: TaskID(
                rawValue: "swift-sdk.build-linux-\(architecture.rawValue)-runtime"),
            component: component)
        taskBuilder.consume(sysroot)
        taskBuilder.consume(builder.image)
        let install: ArtifactReference<DirectoryArtifact> = try taskBuilder.output(
            "runtime-install",
            path: target.runtimeInstall,
            validation: .nonEmptyDirectory)
        let _: ArtifactReference<FileArtifact> = try taskBuilder.output(
            "swift-core-runtime",
            path: runtimeLibrary,
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try taskBuilder.output(
            "swift-testing-module",
            path: swiftTestingModule,
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try taskBuilder.output(
            "swift-testing-runtime",
            path: swiftTestingLibrary,
            validation: .regularFile)
        let task = taskBuilder.build(
            inputs: [
                .file(
                    configuration.inputsFile.removingLastComponent().appending(
                        "nucleus-target-runtime-presets.ini")),
                .value(name: "swift-source-gitlinks", bytes: Array(configuration.sourceID.utf8)),
            ],
            locks: [.checkout("swift-linux-\(architecture.rawValue)-runtime")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    BuildSwiftLinuxRuntimeAction(
                        install: target.runtimeInstall,
                        workspace: target.runtimeBuildWorkspace,
                        compilerCache: target.runtimeCompilerCache,
                        execution: OCIExecution(
                            executionPlatform: .linuxARM64OCI,
                            artifactTarget: architecture.artifactTarget,
                            imageID: builder.image.path,
                            hostname: "swift-linux-\(architecture.rawValue)-runtime",
                            workingDirectory: "/src",
                            hostWorkingDirectory: configuration.sourceWorkspace,
                            mounts: mounts,
                            networkPolicy: .externalDisabled,
                            userPolicy: .builder,
                            capabilityPolicy: .dropAll,
                            privilegePolicy: .prohibitAcquisition,
                            processFilesystemPolicy: .standard,
                            resourceLimits: .parallelBuild,
                            containerEnvironment: containerEnvironment,
                            command: ["--reconfigure"],
                            environment: configuration.environment,
                            output: .logged)))
        )
        return RuntimeArtifact(task: task, install: install)
    }

    private static func generatorTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> GeneratorArtifact {
        let executable = configuration.generatorScratch.appending(
            "release/swift-sdk-generator")
        var environment = configuration.environment
        environment.removeValue(forKey: "SWIFTCI_USE_LOCAL_DEPS")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.build-sdk-generator"),
            component: component)
        let artifact: ArtifactReference<ExecutableArtifact> = try builder.output(
            "executable",
            path: executable,
            validation: .executableFile)
        let task = builder.build(
            inputs: [
                .tree(configuration.generatorSource),
                .file(configuration.swiftExecutable),
            ],
            locks: [
                .shared(configuration.generatorScratch.appending(".collider.lock"))
            ],
            action:
                try AnyColliderAction(
                    BuildSwiftSDKGeneratorAction(
                        swift: configuration.swiftExecutable,
                        source: configuration.generatorSource,
                        scratch: configuration.generatorScratch,
                        environment: environment)))
        return GeneratorArtifact(task: task, executable: artifact)
    }

    private static func assemblyTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        downloads: Downloads,
        generator: GeneratorArtifact,
        runtimes: [RuntimeArtifact]
    ) throws -> AssemblyArtifacts {
        let hostToolchain = configuration.candidate.appending("toolchain")
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let androidBundle = "\(configuration.inputs.androidBundleID).artifactbundle"
        let linuxBundle = "\(configuration.inputs.linuxBundleID).artifactbundle"
        let generatorExecutable = generator.executable.path

        var hostEnvironment = configuration.environment
        hostEnvironment["ANDROID_NDK_HOME"] = configuration.ndkRoot.string
        hostEnvironment["PATH"] =
            hostToolchain.appending("usr/bin").string + ":"
            + (hostEnvironment["PATH"] ?? "/usr/bin:/bin")
        hostEnvironment.removeValue(forKey: "SWIFTCI_USE_LOCAL_DEPS")

        var assemblyTargets: [SwiftSDKAssemblyTarget] = []
        for target in configuration.linuxTargets {
            let architecture = target.target.architecture
            let targetDownloads = try linuxDownloads(
                for: architecture,
                in: downloads)
            assemblyTargets.append(
                SwiftSDKAssemblyTarget(
                    architecture: architecture.rawValue,
                    triple: architecture.triple,
                    runtimeInstall: target.runtimeInstall,
                    packages: targetDownloads.allPackages.map(\.path)))
        }
        let manifest = try linuxArtifactBundleManifest(configuration.inputs)
        let metadata = try linuxSwiftSDKMetadata(configuration.inputs)

        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.assemble-target-sdks"),
            component: component)
        for artifact in downloads.artifacts {
            builder.consume(artifact)
        }
        builder.consume(generator.executable)
        for runtime in runtimes {
            builder.consume(runtime.install)
        }
        let hostSwift: ArtifactReference<ExecutableArtifact> = try builder.output(
            "host-swift",
            path: hostToolchain.appending("usr/bin/swift"),
            validation: .executableFile)
        let linuxSDK: ArtifactReference<DirectoryArtifact> = try builder.output(
            "linux-sdk",
            path: sdkRoot.appending(linuxBundle),
            validation: .nonEmptyDirectory)
        let androidSDK: ArtifactReference<DirectoryArtifact> = try builder.output(
            "android-sdk",
            path: sdkRoot.appending(androidBundle),
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [
                .file(configuration.inputsFile),
                .file(configuration.ndkRoot.appending("source.properties")),
            ],
            locks: [
                .shared(configuration.generatorScratch.appending(".collider.lock"))
            ],
            action:
                try AnyColliderAction(
                    AssembleSwiftTargetSDKsAction(
                        candidate: configuration.candidate,
                        hostArchive: downloads.host.artifact.path,
                        androidArchive: downloads.android.artifact.path,
                        ndkRoot: configuration.ndkRoot,
                        generator: generatorExecutable,
                        snapshot: configuration.inputs.snapshot,
                        linuxBundleID: configuration.inputs.linuxBundleID,
                        androidBundleID: configuration.inputs.androidBundleID,
                        targets: assemblyTargets,
                        linuxManifest: manifest,
                        linuxMetadata: metadata,
                        environment: hostEnvironment))
        )
        return AssemblyArtifacts(
            task: task,
            hostSwift: hostSwift,
            linuxSDK: linuxSDK,
            androidSDK: androidSDK)
    }

    private static func linuxArtifactBundleManifest(
        _ inputs: SwiftTargetSDKInputs
    ) throws -> [UInt8] {
        try jsonBytes([
            "schemaVersion": "1.0",
            "artifacts": [
                inputs.linuxBundleID: [
                    "type": "swiftSDK",
                    "version": inputs.snapshot,
                    "variants": [["path": "swift-linux"]],
                ]
            ],
        ])
    }

    private static func linuxSwiftSDKMetadata(
        _ inputs: SwiftTargetSDKInputs
    ) throws -> [UInt8] {
        var targetTriples: [String: Any] = [:]
        for target in inputs.linuxTargets {
            let triple = target.architecture.triple
            let sdkRoot = "\(triple)/ubuntu-noble.sdk"
            targetTriples[triple] = [
                "sdkRootPath": sdkRoot,
                "swiftResourcesPath": "\(sdkRoot)/usr/lib/swift",
                "swiftStaticResourcesPath": "\(sdkRoot)/usr/lib/swift_static",
                "toolsetPaths": ["\(triple)/toolset.json"],
            ]
        }
        return try jsonBytes([
            "schemaVersion": "4.0",
            "targetTriples": targetTriples,
        ])
    }

    private static func jsonBytes(_ object: Any) throws -> [UInt8] {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return Array(data)
    }

    private static func linuxDownloads(
        for architecture: SwiftTargetSDKInputs.LinuxArchitecture,
        in downloads: Downloads
    ) throws -> LinuxDownloads {
        guard
            let target = downloads.linux.first(where: {
                $0.architecture == architecture
            })
        else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "missing Linux downloads for \(architecture.rawValue)")
        }
        return target
    }

    private static func validationTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        assembly: AssemblyArtifacts
    ) throws -> ValidationArtifacts {
        let hostSwift = assembly.hostSwift.path
        let hostLinker = hostSwift.removingLastComponent().appending("ld.lld")
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let validationRoot = configuration.candidate.appending("validation")
        let hostToolset = validationRoot.appending("host-toolset.json")
        let hostToolsetBytes = try jsonBytes([
            "schemaVersion": "1.0",
            "linker": ["path": hostLinker.string],
        ])
        let linuxARM64Build = validationRoot.appending("linux-arm64")
        let linuxAMD64Build = validationRoot.appending("linux-x86_64")
        let androidARM64Build = validationRoot.appending("android-arm64")
        let androidAMD64Build = validationRoot.appending("android-amd64")
        let linuxARM64Executable = linuxARM64Build.appending(
            "out/Products/Debug-linux-aarch64/hello")
        let linuxAMD64Executable = linuxAMD64Build.appending(
            "out/Products/Debug-linux-x86_64/hello")
        let androidARM64Executable = androidARM64Build.appending(
            "out/Products/Debug-android-aarch64/hello")
        let androidAMD64Executable = androidAMD64Build.appending(
            "out/Products/Debug-android-x86_64/hello")
        var environment = configuration.environment
        environment["ANDROID_NDK_HOME"] = configuration.ndkRoot.string

        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.validate-target-sdks"),
            component: component)
        builder.consume(assembly.hostSwift)
        builder.consume(assembly.linuxSDK)
        builder.consume(assembly.androidSDK)
        let executablePaths = [
            linuxARM64Executable,
            linuxAMD64Executable,
            androidARM64Executable,
            androidAMD64Executable,
        ]
        let executables: [ArtifactReference<ExecutableArtifact>] = try executablePaths.enumerated()
            .map { index, path in
                try builder.output(
                    OutputSlotID(rawValue: "executable-\(index)"),
                    path: path,
                    validation: .executableFile)
            }
        let task = builder.build(
            inputs: [
                .tree(configuration.validationFixture),
                .file(configuration.validator),
            ],
            action:
                try AnyColliderAction(
                    ValidateSwiftTargetSDKsAction(
                        hostSwift: hostSwift,
                        hostToolset: hostToolset,
                        hostToolsetBytes: hostToolsetBytes,
                        sdkRoot: sdkRoot,
                        linuxSDK: assembly.linuxSDK.path,
                        validationRoot: validationRoot,
                        fixture: configuration.validationFixture,
                        validator: configuration.validator,
                        ndkRoot: configuration.ndkRoot,
                        linuxBundleID: configuration.inputs.linuxBundleID,
                        androidBundleID: configuration.inputs.androidBundleID,
                        androidAPILevel: configuration.androidAPILevel,
                        executablePaths: executablePaths,
                        environment: environment)))
        return ValidationArtifacts(task: task, executables: executables)
    }

    private static func activationTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        validation: ValidationArtifacts
    ) throws -> ActivationArtifact {
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.activate-target-sdks"),
            component: component)
        for executable in validation.executables {
            builder.consume(executable)
        }
        let marker: ArtifactReference<FileArtifact> = try builder.output(
            "generation-marker",
            path: configuration.generation.appending(
                ".nucleus-target-sdk-generation"),
            validation: .regularFile)
        let activeSDK: ArtifactReference<PathArtifact> = try builder.output(
            "active-sdk",
            path: configuration.active,
            validation: .symlinkTarget)
        let task = builder.build(
            postconditions: [
                PathPostcondition(
                    path: configuration.active,
                    validation: .symlinkTarget)
            ],
            assessmentPolicy: .always,
            recordsActiveArtifact: true,
            action:
                try AnyColliderAction(
                    ActivateSwiftSDKGenerationAction(
                        candidate: configuration.candidate,
                        generation: configuration.generation,
                        active: configuration.active)))
        return ActivationArtifact(
            task: task,
            generationMarker: marker,
            activeSDK: activeSDK)
    }

    private static func discoveryTasks(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        activation: ActivationArtifact
    ) throws -> [DiscoveryArtifact] {
        try [configuration.inputs.linuxBundleID, configuration.inputs.androidBundleID]
            .map { bundleID in
                let name = "\(bundleID).artifactbundle"
                let link = configuration.sdkDiscoveryRoot.appending(name)
                let target = configuration.generation.appending(
                    "swift-sdks/\(name)")
                var builder = TaskBuilder(
                    id: TaskID(rawValue: "swift-sdk.discover-\(bundleID)"),
                    component: component)
                builder.consume(activation.generationMarker)
                let artifact: ArtifactReference<PathArtifact> = try builder.output(
                    "discovery-link",
                    path: link,
                    validation: .symlinkTarget)
                let task = builder.build(
                    postconditions: [
                        PathPostcondition(path: link, validation: .symlinkTarget)
                    ],
                    assessmentPolicy: .always,
                    action:
                        try AnyColliderAction(
                            PublishSwiftSDKDiscoveryAction(
                                path: link,
                                target: target.string,
                                displacedItem: configuration.displacedRoot.appending(name))))
                return DiscoveryArtifact(task: task, link: artifact)
            }
    }

    private static func fileName(from value: String) throws -> String {
        guard let url = URL(string: value), !url.lastPathComponent.isEmpty else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "download URL has no file name: \(value)")
        }
        return url.lastPathComponent
    }
}

private struct PrepareSwiftRuntimeBuilderImageAction: ColliderAction {
    static let kind: ActionKind = "swift-sdk.prepare-runtime-builder-image"

    let identity: OCIImagePreparationActionIdentity

    init(preparation: OCIImagePreparation) {
        identity = OCIImagePreparationActionIdentity(preparation)
    }

    var requirements: ActionRequirements {
        ociImagePreparationActionRequirements(preparation: identity.preparation)
    }

    var environment: [String: String] { identity.preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await context.containers.prepareImage(identity.preparation)
    }
}

private struct BuildSwiftLinuxRuntimeAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let install: FilePath
        let workspace: FilePath
        let compilerCache: FilePath
        let execution: OCIExecution

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: install.string)
            encoder.append(tag: 2, string: workspace.string)
            encoder.append(tag: 3, string: compilerCache.string)
            encoder.append(
                tag: 4,
                nested: OCIExecutionActionIdentity(execution))
        }
    }

    static let kind: ActionKind = "swift-sdk.build-linux-runtime"

    let install: FilePath
    let workspace: FilePath
    let compilerCache: FilePath
    let execution: OCIExecution

    var identity: Identity {
        Identity(
            install: install,
            workspace: workspace,
            compilerCache: compilerCache,
            execution: execution)
    }

    var requirements: ActionRequirements {
        let executionRequirements = ociActionRequirements(execution: execution)
        return ActionRequirements(
            effects: executionRequirements.effects + [
                ActionEffect(.readWrite, scope: .output(install)),
                ActionEffect(.write, scope: .scratch(workspace)),
                ActionEffect(.write, scope: .scratch(compilerCache)),
            ],
            resources: executionRequirements.resources,
            executionPlatform: executionRequirements.executionPlatform,
            artifactTarget: executionRequirements.artifactTarget)
    }

    var environment: [String: String] { execution.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(install)
        try context.files.createDirectory(install)
        try context.files.createDirectory(workspace)
        try context.files.createDirectory(compilerCache)
        try await context.containers.run(execution)
    }
}

private struct DownloadSwiftTargetSDKInputAction: ColliderAction {
    static let kind: ActionKind = "swift-sdk.download-input"

    let identity: DownloadActionIdentity

    init(specification: DownloadSpec, destination: FilePath) {
        identity = DownloadActionIdentity(
            specification: specification,
            destination: destination)
    }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .output(identity.destination))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try await context.downloads.download(
            identity.specification,
            to: identity.destination)
    }

    func validateOutputs(using files: ActionFileSystem) throws {
        try identity.validateOutput(using: files)
    }
}

private struct ActivateSwiftSDKGenerationAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let candidate: FilePath
        let generation: FilePath
        let active: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: candidate.string)
            encoder.append(tag: 2, string: generation.string)
            encoder.append(tag: 3, string: active.string)
        }
    }

    static let kind: ActionKind = "swift-sdk.activate-generation"

    let candidate: FilePath
    let generation: FilePath
    let active: FilePath

    var identity: Identity {
        Identity(candidate: candidate, generation: generation, active: active)
    }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .output(candidate)),
            ActionEffect(.write, scope: .output(generation)),
            ActionEffect(.write, scope: .publication(active)),
        ])
    }

    func execute(in context: ActionContext) async throws {
        let marker = candidate.appending(".nucleus-target-sdk-generation")
        guard try context.files.metadata(for: marker)?.type == .regular else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "target SDK candidate has no generation marker at \(marker)")
        }
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generation,
            active: active)
    }
}

private struct SwiftSDKAssemblyTarget: Hashable, Sendable {
    let architecture: String
    let triple: String
    let runtimeInstall: FilePath
    let packages: [FilePath]
}

package struct PublishSwiftSDKDiscoveryAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let path: FilePath
        let target: String
        let displacedItem: FilePath

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: path.string)
            encoder.append(tag: 2, string: target)
            encoder.append(tag: 3, string: displacedItem.string)
        }
    }

    package static let kind: ActionKind = "swift-sdk.publish-discovery"

    private let path: FilePath
    private let target: String
    private let displacedItem: FilePath

    package init(path: FilePath, target: String, displacedItem: FilePath) {
        self.path = path
        self.target = target
        self.displacedItem = displacedItem
    }

    package var identity: Identity {
        Identity(path: path, target: target, displacedItem: displacedItem)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .publication(path)),
            ActionEffect(.readWrite, scope: .publication(displacedItem)),
        ])
    }

    package func execute(in context: ActionContext) async throws {
        let existing = try context.files.metadataWithoutFollowingSymlinks(for: path)
        if existing?.type == .symbolicLink {
            try context.files.replaceSymlink(at: path, target: target)
            return
        }
        var displaced = false
        if existing != nil {
            guard
                try context.files.metadataWithoutFollowingSymlinks(
                    for: displacedItem) == nil
            else {
                throw SwiftTargetSDKRecipeFailure.invalidInput(
                    "cannot preserve \(path); displacement already exists at "
                        + displacedItem.string)
            }
            try context.files.move(from: path, to: displacedItem)
            displaced = true
        }
        do {
            try context.files.replaceSymlink(at: path, target: target)
        } catch {
            if displaced {
                try? context.files.move(from: displacedItem, to: path)
            }
            throw error
        }
    }
}

private struct AssembleSwiftTargetSDKsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let candidate: FilePath
        let hostArchive: FilePath
        let androidArchive: FilePath
        let ndkRoot: FilePath
        let generator: FilePath
        let snapshot: String
        let linuxBundleID: String
        let androidBundleID: String
        let targets: [SwiftSDKAssemblyTarget]
        let linuxManifest: [UInt8]
        let linuxMetadata: [UInt8]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: candidate.string)
            encoder.append(tag: 2, string: hostArchive.string)
            encoder.append(tag: 3, string: androidArchive.string)
            encoder.append(tag: 4, string: ndkRoot.string)
            encoder.append(tag: 5, string: generator.string)
            encoder.append(tag: 6, string: snapshot)
            encoder.append(tag: 7, string: linuxBundleID)
            encoder.append(tag: 8, string: androidBundleID)
            encoder.append(
                tag: 9,
                string: targets.map { target in
                    [
                        target.architecture,
                        target.triple,
                        target.runtimeInstall.string,
                        target.packages.map(\.string).joined(separator: "\u{1}"),
                    ].joined(separator: "\u{2}")
                }.joined(separator: "\0"))
            encoder.append(tag: 10, bytes: linuxManifest)
            encoder.append(tag: 11, bytes: linuxMetadata)
        }
    }

    static let kind: ActionKind = "swift-sdk.assemble-target-sdks"

    let candidate: FilePath
    let hostArchive: FilePath
    let androidArchive: FilePath
    let ndkRoot: FilePath
    let generator: FilePath
    let snapshot: String
    let linuxBundleID: String
    let androidBundleID: String
    let targets: [SwiftSDKAssemblyTarget]
    let linuxManifest: [UInt8]
    let linuxMetadata: [UInt8]
    let environment: [String: String]

    var identity: Identity {
        Identity(
            candidate: candidate,
            hostArchive: hostArchive,
            androidArchive: androidArchive,
            ndkRoot: ndkRoot,
            generator: generator,
            snapshot: snapshot,
            linuxBundleID: linuxBundleID,
            androidBundleID: androidBundleID,
            targets: targets,
            linuxManifest: linuxManifest,
            linuxMetadata: linuxMetadata)
    }

    var requirements: ActionRequirements {
        let packagePaths = Set(targets.flatMap(\.packages)).sorted {
            $0.string < $1.string
        }
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "pkgutil",
                    executable: .path(FilePath("/usr/sbin/pkgutil")),
                    role: .operational),
                ActionToolRequirement(
                    "ditto",
                    executable: .path(FilePath("/usr/bin/ditto")),
                    role: .operational),
                ActionToolRequirement(
                    "tar",
                    executable: .path(FilePath("/usr/bin/tar")),
                    role: .operational),
                ActionToolRequirement(
                    "swift-sdk-generator",
                    executable: .taskOutput(generator),
                    role: .operational),
                ActionToolRequirement(
                    "android-sdk-setup",
                    executable: .taskOutput(androidSetupScript),
                    role: .operational),
            ],
            effects: [
                ActionEffect(.read, scope: .input(hostArchive)),
                ActionEffect(.read, scope: .input(androidArchive)),
                ActionEffect(.read, scope: .input(ndkRoot)),
                ActionEffect(.read, scope: .input(generator)),
                ActionEffect(.readWrite, scope: .output(candidate)),
            ]
                + targets.map {
                    ActionEffect(.read, scope: .input($0.runtimeInstall))
                }
                + packagePaths.map {
                    ActionEffect(.read, scope: .input($0))
                })
    }

    private var sdkRoot: FilePath { candidate.appending("swift-sdks") }
    private var linuxBundle: String { "\(linuxBundleID).artifactbundle" }
    private var androidBundle: String { "\(androidBundleID).artifactbundle" }
    private var androidSetupScript: FilePath {
        sdkRoot.appending("\(androidBundle)/swift-android/scripts/setup-android-sdk.sh")
    }

    func execute(in context: ActionContext) async throws {
        let expandedHost = candidate.appending("host-package")
        let hostPayload = expandedHost.appending(
            "\(snapshot)-osx-package.pkg/Payload")
        let hostToolchain = candidate.appending("toolchain")
        let generatedLinux = candidate.appending("generated-linux")
        let finalLinuxBundle = sdkRoot.appending(linuxBundle)
        let finalLinuxSDK = finalLinuxBundle.appending("swift-linux")

        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        try await run(
            executable: .path(FilePath("/usr/sbin/pkgutil")),
            arguments: ["--expand-full", hostArchive.string, expandedHost.string],
            workingDirectory: candidate,
            context: context)
        try context.files.createDirectory(hostToolchain)
        try await run(
            executable: .path(FilePath("/usr/bin/ditto")),
            arguments: [
                hostPayload.appending("usr").string,
                hostToolchain.appending("usr").string,
            ],
            workingDirectory: candidate,
            context: context)
        try context.files.createDirectory(sdkRoot)
        try context.files.createDirectory(finalLinuxSDK)

        for target in targets {
            let generatedTarget = generatedLinux.appending(target.architecture)
            let temporarySDKName = "\(linuxBundleID)-\(target.architecture)"
            let generatedTripleRoot = generatedTarget.appending(
                "Bundles/\(linuxBundle)/\(temporarySDKName)/\(target.triple)")
            var arguments = [
                "make-linux-sdk",
                "--no-host-toolchain",
                "--target", target.triple,
                "--distribution-name", "ubuntu",
                "--distribution-version", "24.04",
                "--swift-version", snapshot,
                "--target-swift-package-path", target.runtimeInstall.string,
                "--sdk-name", temporarySDKName,
                "--bundle-name", linuxBundleID,
                "--bundle-version", snapshot,
                "--output-path", generatedTarget.string,
            ]
            for package in target.packages {
                arguments += ["--target-system-package-path", package.string]
            }
            try await run(
                executable: .taskOutput(generator),
                arguments: arguments,
                workingDirectory: candidate,
                context: context)
            try await run(
                executable: .path(FilePath("/usr/bin/ditto")),
                arguments: [
                    target.runtimeInstall.appending("usr").string,
                    generatedTripleRoot.appending("ubuntu-noble.sdk/usr").string,
                ],
                workingDirectory: candidate,
                context: context)
            try await run(
                executable: .path(FilePath("/usr/bin/ditto")),
                arguments: [
                    generatedTripleRoot.string,
                    finalLinuxSDK.appending(target.triple).string,
                ],
                workingDirectory: candidate,
                context: context)
        }

        try context.files.write(
            linuxManifest,
            to: finalLinuxBundle.appending("info.json"))
        try context.files.write(
            linuxMetadata,
            to: finalLinuxSDK.appending("swift-sdk.json"))
        try await run(
            executable: .path(FilePath("/usr/bin/tar")),
            arguments: ["-xzf", androidArchive.string, "-C", sdkRoot.string],
            workingDirectory: candidate,
            context: context)
        try await run(
            executable: .taskOutput(androidSetupScript),
            arguments: [],
            workingDirectory: sdkRoot,
            context: context)
        try context.files.write(
            Array(snapshot.utf8),
            to: candidate.appending(".nucleus-target-sdk-generation"))
    }

    private func run(
        executable: CommandSpec.Executable,
        arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                output: .logged))
        guard result.status == 0 else {
            throw SwiftSDKAssemblyFailure.commandFailed(result.status)
        }
    }
}

private struct BuildSwiftSDKGeneratorAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let swift: FilePath
        let source: FilePath
        let scratch: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: swift.string)
            encoder.append(tag: 2, string: source.string)
            encoder.append(tag: 3, string: scratch.string)
            encoder.append(tag: 4, string: "swift-sdk-generator")
            encoder.append(tag: 5, string: "release")
        }
    }

    static let kind: ActionKind = "swift-sdk.build-generator"

    let swift: FilePath
    let source: FilePath
    let scratch: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(swift: swift, source: source, scratch: scratch)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "swift",
                    executable: .path(swift),
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .checkout(source)),
                ActionEffect(.readWrite, scope: .scratch(scratch)),
            ])
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .path(swift),
                arguments: [
                    "build",
                    "--package-path", source.string,
                    "--scratch-path", scratch.string,
                    "--disable-automatic-resolution",
                    "-c", "release",
                    "--product", "swift-sdk-generator",
                ],
                workingDirectory: source,
                environment: environment,
                output: .logged))
        guard result.status == 0 else {
            throw SwiftSDKGeneratorBuildFailure.commandFailed(result.status)
        }
    }
}

private struct ValidateSwiftTargetSDKsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let hostSwift: FilePath
        let hostToolset: FilePath
        let hostToolsetBytes: [UInt8]
        let sdkRoot: FilePath
        let linuxSDK: FilePath
        let validationRoot: FilePath
        let fixture: FilePath
        let validator: FilePath
        let ndkRoot: FilePath
        let linuxBundleID: String
        let androidBundleID: String
        let androidAPILevel: UInt32
        let executablePaths: [FilePath]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: hostSwift.string)
            encoder.append(tag: 2, string: hostToolset.string)
            encoder.append(tag: 3, bytes: hostToolsetBytes)
            encoder.append(tag: 4, string: sdkRoot.string)
            encoder.append(tag: 5, string: linuxSDK.string)
            encoder.append(tag: 6, string: validationRoot.string)
            encoder.append(tag: 7, string: fixture.string)
            encoder.append(tag: 8, string: validator.string)
            encoder.append(tag: 9, string: ndkRoot.string)
            encoder.append(tag: 10, string: linuxBundleID)
            encoder.append(tag: 11, string: androidBundleID)
            encoder.append(tag: 12, integer: UInt64(androidAPILevel))
            encoder.append(
                tag: 13,
                string: executablePaths.map(\.string).joined(separator: "\0"))
        }
    }

    static let kind: ActionKind = "swift-sdk.validate-target-sdks"

    let hostSwift: FilePath
    let hostToolset: FilePath
    let hostToolsetBytes: [UInt8]
    let sdkRoot: FilePath
    let linuxSDK: FilePath
    let validationRoot: FilePath
    let fixture: FilePath
    let validator: FilePath
    let ndkRoot: FilePath
    let linuxBundleID: String
    let androidBundleID: String
    let androidAPILevel: UInt32
    let executablePaths: [FilePath]
    let environment: [String: String]

    var identity: Identity {
        Identity(
            hostSwift: hostSwift,
            hostToolset: hostToolset,
            hostToolsetBytes: hostToolsetBytes,
            sdkRoot: sdkRoot,
            linuxSDK: linuxSDK,
            validationRoot: validationRoot,
            fixture: fixture,
            validator: validator,
            ndkRoot: ndkRoot,
            linuxBundleID: linuxBundleID,
            androidBundleID: androidBundleID,
            androidAPILevel: androidAPILevel,
            executablePaths: executablePaths)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "host-swift",
                    executable: .taskOutput(hostSwift),
                    role: .operational),
                ActionToolRequirement(
                    "sdk-validator",
                    executable: .path(validator),
                    role: .operational),
            ],
            effects: [
                ActionEffect(.read, scope: .input(hostSwift)),
                ActionEffect(.read, scope: .input(sdkRoot)),
                ActionEffect(.read, scope: .checkout(fixture)),
                ActionEffect(.read, scope: .input(validator)),
                ActionEffect(.read, scope: .input(ndkRoot)),
                ActionEffect(.readWrite, scope: .output(validationRoot)),
            ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(validationRoot)
        try context.files.write(hostToolsetBytes, to: hostToolset)
        let builds = [
            (
                validationRoot.appending("linux-arm64"),
                linuxBundleID,
                "aarch64-unknown-linux-gnu"
            ),
            (
                validationRoot.appending("linux-x86_64"),
                linuxBundleID,
                "x86_64-unknown-linux-gnu"
            ),
            (
                validationRoot.appending("android-arm64"),
                androidBundleID,
                "aarch64-unknown-linux-android\(androidAPILevel)"
            ),
            (
                validationRoot.appending("android-amd64"),
                androidBundleID,
                "x86_64-unknown-linux-android\(androidAPILevel)"
            ),
        ]
        for (scratch, sdk, triple) in builds {
            try await run(
                executable: .taskOutput(hostSwift),
                arguments: [
                    "build",
                    "--package-path", fixture.string,
                    "--scratch-path", scratch.string,
                    "--swift-sdks-path", sdkRoot.string,
                    "--swift-sdk", sdk,
                    "--triple", triple,
                    "--toolset", hostToolset.string,
                ],
                workingDirectory: fixture,
                context: context)
        }
        try await run(
            executable: .path(validator),
            arguments: [linuxSDK.string] + executablePaths.map(\.string),
            workingDirectory: validationRoot,
            context: context)
    }

    private func run(
        executable: CommandSpec.Executable,
        arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                output: .logged))
        guard result.status == 0 else {
            throw SwiftSDKValidationFailure.commandFailed(result.status)
        }
    }
}

private struct PrepareLinuxSysrootAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let preparer: FilePath
        let sysroot: FilePath
        let architecture: String
        let packages: [FilePath]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: preparer.string)
            encoder.append(tag: 2, string: sysroot.string)
            encoder.append(tag: 3, string: architecture)
            encoder.append(
                tag: 4,
                string: packages.map(\.string).joined(separator: "\0"))
        }
    }

    static let kind: ActionKind = "swift-sdk.prepare-linux-sysroot"

    let preparer: FilePath
    let sysroot: FilePath
    let architecture: String
    let packages: [FilePath]
    let environment: [String: String]

    var identity: Identity {
        Identity(
            preparer: preparer,
            sysroot: sysroot,
            architecture: architecture,
            packages: packages)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "sysroot-preparer",
                    executable: .path(preparer),
                    role: .operational)
            ],
            effects: packages.map {
                ActionEffect(.read, scope: .input($0))
            } + [
                ActionEffect(
                    .readWrite,
                    scope: .output(sysroot.removingLastComponent()))
            ])
    }

    func execute(in context: ActionContext) async throws {
        let workingDirectory = sysroot.removingLastComponent()
        try context.files.createDirectory(workingDirectory)
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .path(preparer),
                arguments: [sysroot.string, architecture] + packages.map(\.string),
                workingDirectory: workingDirectory,
                environment: environment,
                output: .logged))
        guard result.status == 0 else {
            throw LinuxSysrootPreparationFailure.commandFailed(result.status)
        }
    }
}

private enum SwiftSDKGeneratorBuildFailure: Error {
    case commandFailed(Int32)
}

private enum SwiftSDKValidationFailure: Error {
    case commandFailed(Int32)
}

private enum SwiftSDKAssemblyFailure: Error {
    case commandFailed(Int32)
}

private enum LinuxSysrootPreparationFailure: Error {
    case commandFailed(Int32)
}
