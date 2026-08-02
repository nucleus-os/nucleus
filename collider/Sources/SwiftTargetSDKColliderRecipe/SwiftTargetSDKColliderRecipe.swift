import ColliderCore
import Foundation
import SystemPackage

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
        public let ubuntuPackages: [UbuntuPackage]
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

public struct SwiftTargetSDKGenerationConfiguration: Sendable {
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
        self.environment = environment
    }
}

public struct SwiftTargetSDKTaskSet: Sendable {
    public let tasks: [TaskDeclaration]
    public let selected: [TaskID]
}

public enum SwiftTargetSDKRecipeFailure: Error, CustomStringConvertible, Sendable {
    case invalidInput(String)

    public var description: String {
        switch self {
        case .invalidInput(let message): message
        }
    }
}

public enum SwiftTargetSDKColliderRecipe {
    private static let component = ComponentID(rawValue: "swift-sdk")

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
        let runtimeBuilder = runtimeBuilderTask(configuration)
        let sysroots = try configuration.linuxTargets.map { target in
            linuxSysrootTask(
                configuration,
                target: target,
                downloads: try linuxDownloads(
                    for: target.target.architecture,
                    in: downloads))
        }
        let runtimes = zip(configuration.linuxTargets, sysroots).map { target, sysroot in
            linuxRuntimeTask(
                configuration,
                target: target,
                builder: runtimeBuilder,
                sysroot: sysroot)
        }
        let generator = generatorTask(configuration)
        let assembly = try assemblyTask(
            configuration,
            downloads: downloads,
            generator: generator,
            runtimes: runtimes)
        let validation = validationTask(configuration, assembly: assembly)
        let activation = activationTask(configuration, validation: validation)
        let discoveries = discoveryTasks(configuration, activation: activation)

        return SwiftTargetSDKTaskSet(
            tasks: downloads.tasks
                + [runtimeBuilder] + sysroots + runtimes
                + [generator, assembly, validation, activation]
                + discoveries,
            selected: discoveries.map(\.id))
    }

    private struct Downloads {
        let tasks: [TaskDeclaration]
        let host: FilePath
        let android: FilePath
        let linux: [LinuxDownloads]
    }

    private struct LinuxDownloads {
        let architecture: SwiftTargetSDKInputs.LinuxArchitecture
        let tasks: [TaskDeclaration]
        let packages: [FilePath]
    }

    private static func validate(_ inputs: SwiftTargetSDKInputs) throws {
        guard !inputs.snapshot.isEmpty,
            inputs.linuxTargets.map(\.architecture).sorted(by: { $0.rawValue < $1.rawValue })
                == SwiftTargetSDKInputs.LinuxArchitecture.allCases.sorted(by: {
                    $0.rawValue < $1.rawValue
                }),
            inputs.linuxTargets.allSatisfy({ !$0.ubuntuPackages.isEmpty })
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
            let tasks = try target.ubuntuPackages.enumerated().map { index, package in
                let name = try fileName(from: package.url)
                return try downloadTask(
                    id: "swift-sdk.download-ubuntu-\(target.architecture.rawValue)-\(index)",
                    input: SwiftTargetSDKInputs.Input(
                        maximumResponseSize: 32 * 1_024 * 1_024,
                        sha256: package.sha256,
                        url: package.url),
                    destination: configuration.downloadRoot.appending(
                        "ubuntu/\(target.architecture.rawValue)/\(name)"))
            }
            return LinuxDownloads(
                architecture: target.architecture,
                tasks: tasks,
                packages: tasks.map { $0.outputs[0].path })
        }
        return Downloads(
            tasks: [host, android] + linux.flatMap(\.tasks),
            host: host.outputs[0].path,
            android: android.outputs[0].path,
            linux: linux)
    }

    private static func downloadTask(
        id: String,
        input: SwiftTargetSDKInputs.Input,
        destination: FilePath
    ) throws -> TaskDeclaration {
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
        return TaskDeclaration(
            id: TaskID(rawValue: id),
            component: component,
            outputs: [
                OutputDeclaration(path: destination, validation: .regularFile)
            ],
            locks: [.checkout("swift-target-sdk-downloads")],
            operation: .download(specification, candidate: destination))
    }

    private static func runtimeBuilderTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) -> TaskDeclaration {
        return TaskDeclaration(
            id: TaskID(rawValue: "swift-sdk.prepare-linux-runtime-builder"),
            component: component,
            inputs: [.tree(configuration.runtimeBuilderContext)],
            outputs: [
                OutputDeclaration(
                    path: configuration.runtimeBuilderImageID,
                    validation: .regularFile)
            ],
            locks: [.checkout("swift-linux-runtime-builder-image")],
            cachePolicy: .contentAddressed,
            operation: .prepareOCIImage(
                OCIImagePreparation(
                    executionPlatform: .linuxARM64OCI,
                    context: configuration.runtimeBuilderContext,
                    containerFile: configuration.runtimeBuilderContext.appending(
                        "Containerfile"),
                    imageID: configuration.runtimeBuilderImageID,
                    imageName: "localhost/nucleus-swift-runtime-build",
                    environment: configuration.environment)))
    }

    private static func linuxSysrootTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        target: SwiftLinuxTargetBuildConfiguration,
        downloads: LinuxDownloads
    ) -> TaskDeclaration {
        let architecture = target.target.architecture
        return TaskDeclaration(
            id: TaskID(
                rawValue:
                    "swift-sdk.prepare-linux-\(architecture.rawValue)-libcxx-sysroot"),
            component: component,
            dependencies: downloads.tasks.map(\.id),
            inputs: [.file(configuration.sysrootPreparer)]
                + downloads.packages.map { .dependencyOutput($0) },
            outputs: [
                OutputDeclaration(
                    path: target.sysroot,
                    validation: .nonEmptyDirectory)
            ],
            cachePolicy: .contentAddressed,
            operation: .sequence([
                .createDirectory(target.sysroot.removingLastComponent()),
                .command(
                    CommandSpec(
                        executable: .path(configuration.sysrootPreparer),
                        arguments: [
                            target.sysroot.string,
                            architecture.gnuArchitecture,
                        ] + downloads.packages.map(\.string),
                        workingDirectory: target.sysroot.removingLastComponent(),
                        environment: configuration.environment,
                        output: .logged)),
            ]))
    }

    private static func linuxRuntimeTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        target: SwiftLinuxTargetBuildConfiguration,
        builder: TaskDeclaration,
        sysroot: TaskDeclaration
    ) -> TaskDeclaration {
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
        return TaskDeclaration(
            id: TaskID(
                rawValue: "swift-sdk.build-linux-\(architecture.rawValue)-runtime"),
            component: component,
            dependencies: [builder.id, sysroot.id],
            inputs: [
                .dependencyOutput(configuration.runtimeBuilderImageID),
                .dependencyOutput(target.sysroot),
                .file(
                    configuration.inputsFile.removingLastComponent().appending(
                        "nucleus-target-runtime-presets.ini")),
                .value(name: "swift-source-gitlinks", bytes: Array(configuration.sourceID.utf8)),
            ],
            outputs: [
                OutputDeclaration(path: runtimeLibrary, validation: .regularFile),
                OutputDeclaration(path: swiftTestingModule, validation: .regularFile),
                OutputDeclaration(path: swiftTestingLibrary, validation: .regularFile),
            ],
            locks: [.checkout("swift-linux-\(architecture.rawValue)-runtime")],
            cachePolicy: .contentAddressed,
            operation: .sequence([
                .removePath(target.runtimeInstall),
                .createDirectory(target.runtimeInstall),
                .createDirectory(target.runtimeBuildWorkspace),
                .createDirectory(target.runtimeCompilerCache),
                .runOCI(
                    OCIExecution(
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: architecture.artifactTarget,
                        imageID: configuration.runtimeBuilderImageID,
                        hostname: "swift-linux-\(architecture.rawValue)-runtime",
                        workingDirectory: "/src",
                        hostWorkingDirectory: configuration.sourceWorkspace,
                        mounts: mounts,
                        networkPolicy: .externalDisabled,
                        userPolicy: .builder,
                        capabilityPolicy: .dropAll,
                        privilegePolicy: .prohibitAcquisition,
                        processFilesystemPolicy: .standard,
                        resourceLimits: .build,
                        containerEnvironment: containerEnvironment,
                        command: ["--reconfigure"],
                        environment: configuration.environment,
                        output: .logged)),
            ]))
    }

    private static func generatorTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) -> TaskDeclaration {
        let executable = configuration.generatorScratch.appending(
            "release/swift-sdk-generator")
        var environment = configuration.environment
        environment.removeValue(forKey: "SWIFTCI_USE_LOCAL_DEPS")
        return TaskDeclaration(
            id: TaskID(rawValue: "swift-sdk.build-sdk-generator"),
            component: component,
            inputs: [
                .tree(configuration.generatorSource),
                .file(configuration.swiftExecutable),
            ],
            outputs: [
                OutputDeclaration(path: executable, validation: .executableFile)
            ],
            locks: [
                .shared(configuration.generatorScratch.appending(".collider.lock"))
            ],
            operation: .command(
                CommandSpec(
                    executable: .path(configuration.swiftExecutable),
                    arguments: [
                        "build",
                        "--package-path", configuration.generatorSource.string,
                        "--scratch-path", configuration.generatorScratch.string,
                        "--disable-automatic-resolution",
                        "-c", "release",
                        "--product", "swift-sdk-generator",
                    ],
                    workingDirectory: configuration.generatorSource,
                    environment: environment,
                    output: .logged)))
    }

    private static func assemblyTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        downloads: Downloads,
        generator: TaskDeclaration,
        runtimes: [TaskDeclaration]
    ) throws -> TaskDeclaration {
        let expandedHost = configuration.candidate.appending("host-package")
        let hostPayload = expandedHost.appending(
            "\(configuration.inputs.snapshot)-osx-package.pkg/Payload")
        let hostToolchain = configuration.candidate.appending("toolchain")
        let generatedLinux = configuration.candidate.appending("generated-linux")
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let androidBundle = "\(configuration.inputs.androidBundleID).artifactbundle"
        let linuxBundle = "\(configuration.inputs.linuxBundleID).artifactbundle"
        let finalLinuxBundle = sdkRoot.appending(linuxBundle)
        let finalLinuxSDK = finalLinuxBundle.appending("swift-linux")
        let generatorExecutable = generator.outputs[0].path

        var hostEnvironment = configuration.environment
        hostEnvironment["ANDROID_NDK_HOME"] = configuration.ndkRoot.string
        hostEnvironment.removeValue(forKey: "SWIFTCI_USE_LOCAL_DEPS")

        var operations: [TaskOperation] = [
            .removePath(configuration.candidate),
            .createDirectory(configuration.candidate),
            .command(
                CommandSpec(
                    executable: .path(FilePath("/usr/sbin/pkgutil")),
                    arguments: [
                        "--expand-full", downloads.host.string,
                        expandedHost.string,
                    ],
                    workingDirectory: configuration.candidate,
                    environment: hostEnvironment,
                    output: .logged)),
            .createDirectory(hostToolchain),
            .command(
                CommandSpec(
                    executable: .path(FilePath("/usr/bin/ditto")),
                    arguments: [
                        hostPayload.appending("usr").string,
                        hostToolchain.appending("usr").string,
                    ],
                    workingDirectory: configuration.candidate,
                    environment: hostEnvironment,
                    output: .logged)),
            .createDirectory(sdkRoot),
            .createDirectory(finalLinuxSDK),
        ]

        for target in configuration.linuxTargets {
            let architecture = target.target.architecture
            let targetDownloads = try linuxDownloads(
                for: architecture,
                in: downloads)
            let generatedTarget = generatedLinux.appending(architecture.rawValue)
            let temporarySDKName = "\(configuration.inputs.linuxBundleID)-\(architecture.rawValue)"
            let generatedTripleRoot = generatedTarget.appending(
                "Bundles/\(linuxBundle)/\(temporarySDKName)/\(architecture.triple)")
            var generatorArguments = [
                "make-linux-sdk",
                "--no-host-toolchain",
                "--target", architecture.triple,
                "--distribution-name", "ubuntu",
                "--distribution-version", "24.04",
                "--swift-version", configuration.inputs.snapshot,
                "--target-swift-package-path", target.runtimeInstall.string,
                "--sdk-name", temporarySDKName,
                "--bundle-name", configuration.inputs.linuxBundleID,
                "--bundle-version", configuration.inputs.snapshot,
                "--output-path", generatedTarget.string,
            ]
            for package in targetDownloads.packages {
                generatorArguments += ["--target-system-package-path", package.string]
            }
            operations += [
                .command(
                    CommandSpec(
                        executable: .taskOutput(generatorExecutable),
                        arguments: generatorArguments,
                        workingDirectory: configuration.candidate,
                        environment: hostEnvironment,
                        output: .logged)),
                .command(
                    CommandSpec(
                        executable: .path(FilePath("/usr/bin/ditto")),
                        arguments: [
                            target.runtimeInstall.appending("usr").string,
                            generatedTripleRoot.appending("ubuntu-noble.sdk/usr").string,
                        ],
                        workingDirectory: configuration.candidate,
                        environment: hostEnvironment,
                        output: .logged)),
                .command(
                    CommandSpec(
                        executable: .path(FilePath("/usr/bin/ditto")),
                        arguments: [
                            generatedTripleRoot.string,
                            finalLinuxSDK.appending(architecture.triple).string,
                        ],
                        workingDirectory: configuration.candidate,
                        environment: hostEnvironment,
                        output: .logged)),
            ]
        }

        operations += [
            .writeFile(
                finalLinuxBundle.appending("info.json"),
                bytes: try linuxArtifactBundleManifest(configuration.inputs)),
            .writeFile(
                finalLinuxSDK.appending("swift-sdk.json"),
                bytes: try linuxSwiftSDKMetadata(configuration.inputs)),
            .command(
                CommandSpec(
                    executable: .path(FilePath("/usr/bin/tar")),
                    arguments: [
                        "-xzf", downloads.android.string,
                        "-C", sdkRoot.string,
                    ],
                    workingDirectory: configuration.candidate,
                    environment: hostEnvironment,
                    output: .logged)),
            .command(
                CommandSpec(
                    executable: .taskOutput(
                        sdkRoot.appending(
                            "\(androidBundle)/swift-android/scripts/setup-android-sdk.sh")),
                    arguments: [],
                    workingDirectory: sdkRoot,
                    environment: hostEnvironment,
                    output: .logged)),
            .writeFile(
                configuration.candidate.appending(".nucleus-target-sdk-generation"),
                bytes: Array(configuration.inputs.snapshot.utf8)),
        ]

        return TaskDeclaration(
            id: TaskID(rawValue: "swift-sdk.assemble-target-sdks"),
            component: component,
            dependencies: downloads.tasks.map(\.id) + [generator.id] + runtimes.map(\.id),
            inputs: [
                .file(configuration.inputsFile),
                .file(configuration.ndkRoot.appending("source.properties")),
            ] + downloads.tasks.map { .dependencyOutput($0.outputs[0].path) }
                + [
                    .dependencyOutput(generatorExecutable)
                ] + runtimes.map { .dependencyOutput($0.outputs[0].path) },
            outputs: [
                OutputDeclaration(
                    path: hostToolchain.appending("usr/bin/swift"),
                    validation: .executableFile),
                OutputDeclaration(
                    path: sdkRoot.appending(linuxBundle),
                    validation: .nonEmptyDirectory),
                OutputDeclaration(
                    path: sdkRoot.appending(androidBundle),
                    validation: .nonEmptyDirectory),
            ],
            locks: [
                .shared(configuration.generatorScratch.appending(".collider.lock"))
            ],
            operation: .sequence(operations))
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
        assembly: TaskDeclaration
    ) -> TaskDeclaration {
        let hostSwift = assembly.outputs[0].path
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let validationRoot = configuration.candidate.appending("validation")
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

        func build(_ scratch: FilePath, sdk: String, triple: String) -> TaskOperation {
            .command(
                CommandSpec(
                    executable: .taskOutput(hostSwift),
                    arguments: [
                        "build",
                        "--package-path", configuration.validationFixture.string,
                        "--scratch-path", scratch.string,
                        "--swift-sdks-path", sdkRoot.string,
                        "--swift-sdk", sdk,
                        "--triple", triple,
                    ],
                    workingDirectory: configuration.validationFixture,
                    environment: environment,
                    output: .logged))
        }

        return TaskDeclaration(
            id: TaskID(rawValue: "swift-sdk.validate-target-sdks"),
            component: component,
            dependencies: [assembly.id],
            inputs: [
                .dependencyOutput(hostSwift),
                .dependencyOutput(assembly.outputs[1].path),
                .dependencyOutput(assembly.outputs[2].path),
                .tree(configuration.validationFixture),
                .file(configuration.validator),
            ],
            outputs: [
                OutputDeclaration(
                    path: linuxARM64Executable, validation: .executableFile),
                OutputDeclaration(
                    path: linuxAMD64Executable, validation: .executableFile),
                OutputDeclaration(
                    path: androidARM64Executable, validation: .executableFile),
                OutputDeclaration(
                    path: androidAMD64Executable, validation: .executableFile),
            ],
            operation: .sequence([
                .createDirectory(validationRoot),
                build(
                    linuxARM64Build,
                    sdk: configuration.inputs.linuxBundleID,
                    triple: "aarch64-unknown-linux-gnu"),
                build(
                    linuxAMD64Build,
                    sdk: configuration.inputs.linuxBundleID,
                    triple: "x86_64-unknown-linux-gnu"),
                build(
                    androidARM64Build,
                    sdk: configuration.inputs.androidBundleID,
                    triple:
                        "aarch64-unknown-linux-android\(configuration.androidAPILevel)"),
                build(
                    androidAMD64Build,
                    sdk: configuration.inputs.androidBundleID,
                    triple:
                        "x86_64-unknown-linux-android\(configuration.androidAPILevel)"),
                .command(
                    CommandSpec(
                        executable: .path(configuration.validator),
                        arguments: [
                            assembly.outputs[1].path.string,
                            linuxARM64Executable.string,
                            linuxAMD64Executable.string,
                            androidARM64Executable.string,
                            androidAMD64Executable.string,
                        ],
                        workingDirectory: validationRoot,
                        environment: environment,
                        output: .logged)),
            ]))
    }

    private static func activationTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        validation: TaskDeclaration
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "swift-sdk.activate-target-sdks"),
            component: component,
            dependencies: [validation.id],
            inputs: validation.outputs.map { .dependencyOutput($0.path) },
            outputs: [
                OutputDeclaration(
                    path: configuration.generation.appending(
                        ".nucleus-target-sdk-generation"),
                    validation: .regularFile)
            ],
            postconditions: [
                PathPostcondition(path: configuration.active, validation: .exists)
            ],
            cachePolicy: .always,
            operation: .activateGeneration(
                candidate: configuration.candidate,
                generation: configuration.generation,
                active: configuration.active))
    }

    private static func discoveryTasks(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        activation: TaskDeclaration
    ) -> [TaskDeclaration] {
        [configuration.inputs.linuxBundleID, configuration.inputs.androidBundleID]
            .map { bundleID in
                let name = "\(bundleID).artifactbundle"
                let link = configuration.sdkDiscoveryRoot.appending(name)
                let target = configuration.generation.appending(
                    "swift-sdks/\(name)")
                return TaskDeclaration(
                    id: TaskID(rawValue: "swift-sdk.discover-\(bundleID)"),
                    component: component,
                    dependencies: [activation.id],
                    inputs: [.dependencyOutput(activation.outputs[0].path)],
                    outputs: [],
                    postconditions: [
                        PathPostcondition(path: link, validation: .exists)
                    ],
                    cachePolicy: .always,
                    operation: .publishSymlink(
                        SymlinkPublication(
                            path: link,
                            target: target.string,
                            displacedItem: configuration.displacedRoot.appending(name))))
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
