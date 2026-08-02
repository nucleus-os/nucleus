import ColliderCore
import Foundation
import SystemPackage

public struct SwiftTargetSDKLock: Codable, Equatable, Sendable {
    public struct Input: Codable, Equatable, Sendable {
        public let maximumResponseSize: Int64
        public let sha256: String
        public let url: String
    }

    public struct UbuntuPackage: Codable, Equatable, Sendable {
        public let sha256: String
        public let url: String
    }

    public struct Inputs: Codable, Equatable, Sendable {
        public let androidSDK: Input
        public let macOSHostPackage: Input
    }

    public let androidAPILevel: UInt32
    public let androidBundleID: String
    public let inputs: Inputs
    public let linuxBundleID: String
    public let snapshot: String
    public let swiftSDKGeneratorCommit: String
    public let ubuntuPackages: [UbuntuPackage]

    public static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct SwiftTargetSDKGenerationConfiguration: Sendable {
    public let lock: SwiftTargetSDKLock
    public let lockFile: FilePath
    public let downloadRoot: FilePath
    public let generatorSource: FilePath
    public let generatorScratch: FilePath
    public let sourceWorkspace: FilePath
    public let sourceID: String
    public let runtimeBuilderContext: FilePath
    public let runtimeBuilderImageID: FilePath
    public let runtimeBuildWorkspace: FilePath
    public let runtimeCompilerCache: FilePath
    public let runtimeInstall: FilePath
    public let sysrootPreparer: FilePath
    public let linuxSysroot: FilePath
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
        lock: SwiftTargetSDKLock,
        lockFile: FilePath,
        downloadRoot: FilePath,
        generatorSource: FilePath,
        generatorScratch: FilePath,
        sourceWorkspace: FilePath,
        sourceID: String,
        runtimeBuilderContext: FilePath,
        runtimeBuilderImageID: FilePath,
        runtimeBuildWorkspace: FilePath,
        runtimeCompilerCache: FilePath,
        runtimeInstall: FilePath,
        sysrootPreparer: FilePath,
        linuxSysroot: FilePath,
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
        self.lock = lock
        self.lockFile = lockFile
        self.downloadRoot = downloadRoot
        self.generatorSource = generatorSource
        self.generatorScratch = generatorScratch
        self.sourceWorkspace = sourceWorkspace
        self.sourceID = sourceID
        self.runtimeBuilderContext = runtimeBuilderContext
        self.runtimeBuilderImageID = runtimeBuilderImageID
        self.runtimeBuildWorkspace = runtimeBuildWorkspace
        self.runtimeCompilerCache = runtimeCompilerCache
        self.runtimeInstall = runtimeInstall
        self.sysrootPreparer = sysrootPreparer
        self.linuxSysroot = linuxSysroot
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
    private static let component = ComponentID(rawValue: "toolchain")

    public static func generation(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> SwiftTargetSDKTaskSet {
        try validate(configuration.lock)

        let downloads = try downloadTasks(configuration)
        let runtimeBuilder = runtimeBuilderTask(configuration)
        let sysroot = linuxSysrootTask(configuration, downloads: downloads)
        let runtime = linuxRuntimeTask(
            configuration,
            builder: runtimeBuilder,
            sysroot: sysroot)
        let generator = generatorTask(configuration)
        let assembly = assemblyTask(
            configuration,
            downloads: downloads,
            generator: generator,
            runtime: runtime)
        let validation = validationTask(configuration, assembly: assembly)
        let activation = activationTask(configuration, validation: validation)
        let discoveries = discoveryTasks(configuration, activation: activation)

        return SwiftTargetSDKTaskSet(
            tasks: downloads.tasks
                + [runtimeBuilder, sysroot, runtime, generator, assembly, validation, activation]
                + discoveries,
            selected: discoveries.map(\.id))
    }

    private struct Downloads {
        let tasks: [TaskDeclaration]
        let host: FilePath
        let android: FilePath
        let ubuntuTasks: [TaskDeclaration]
        let ubuntu: [FilePath]
    }

    private static func validate(_ lock: SwiftTargetSDKLock) throws {
        guard lock.androidAPILevel >= 24 else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "Swift Android SDK API level must be at least 24")
        }
        guard !lock.androidBundleID.isEmpty, !lock.linuxBundleID.isEmpty,
            !lock.snapshot.isEmpty, lock.swiftSDKGeneratorCommit.count == 40,
            !lock.ubuntuPackages.isEmpty
        else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "Swift target SDK lock is incomplete")
        }
    }

    private static func downloadTasks(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> Downloads {
        let host = try downloadTask(
            id: "toolchain.download-host",
            input: configuration.lock.inputs.macOSHostPackage,
            destination: configuration.downloadRoot.appending("host-macos.pkg"))
        let android = try downloadTask(
            id: "toolchain.download-android-sdk",
            input: configuration.lock.inputs.androidSDK,
            destination: configuration.downloadRoot.appending("android-sdk.tar.gz"))
        let ubuntu = try configuration.lock.ubuntuPackages.enumerated().map {
            index, package in
            let name = try fileName(from: package.url)
            return try downloadTask(
                id: "toolchain.download-ubuntu-\(index)",
                input: SwiftTargetSDKLock.Input(
                    maximumResponseSize: 32 * 1_024 * 1_024,
                    sha256: package.sha256,
                    url: package.url),
                destination: configuration.downloadRoot.appending(
                    "ubuntu/\(name)"))
        }
        return Downloads(
            tasks: [host, android] + ubuntu,
            host: host.outputs[0].path,
            android: android.outputs[0].path,
            ubuntuTasks: ubuntu,
            ubuntu: ubuntu.map { $0.outputs[0].path })
    }

    private static func downloadTask(
        id: String,
        input: SwiftTargetSDKLock.Input,
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
        TaskDeclaration(
            id: TaskID(rawValue: "toolchain.prepare-linux-runtime-builder"),
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
        downloads: Downloads
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "toolchain.prepare-linux-libcxx-sysroot"),
            component: component,
            dependencies: downloads.ubuntuTasks.map(\.id),
            inputs: [.file(configuration.sysrootPreparer)]
                + downloads.ubuntu.map { .dependencyOutput($0) },
            outputs: [
                OutputDeclaration(
                    path: configuration.linuxSysroot,
                    validation: .nonEmptyDirectory)
            ],
            cachePolicy: .contentAddressed,
            operation: .sequence([
                .createDirectory(configuration.linuxSysroot.removingLastComponent()),
                .command(
                    CommandSpec(
                        executable: .path(configuration.sysrootPreparer),
                        arguments: [configuration.linuxSysroot.string]
                            + downloads.ubuntu.map(\.string),
                        workingDirectory: configuration.linuxSysroot.removingLastComponent(),
                        environment: configuration.environment,
                        output: .logged)),
            ]))
    }

    private static func linuxRuntimeTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        builder: TaskDeclaration,
        sysroot: TaskDeclaration
    ) -> TaskDeclaration {
        let runtimeLibrary = configuration.runtimeInstall.appending(
            "usr/lib/swift/linux/libswiftCore.so")
        let mounts = [
            OCIMount(
                source: configuration.sourceWorkspace,
                target: "/src",
                access: .readOnly),
            OCIMount(
                source: configuration.lockFile.removingLastComponent(),
                target: "/recipe",
                access: .readOnly),
            OCIMount(
                source: configuration.runtimeBuildWorkspace,
                target: "/build",
                access: .readWrite),
            OCIMount(
                source: configuration.runtimeCompilerCache,
                target: "/ccache",
                access: .readWrite),
            OCIMount(
                source: configuration.linuxSysroot,
                target: "/usr/x86_64-linux-gnu",
                access: .readOnly),
            OCIMount(
                source: configuration.runtimeInstall,
                target: "/output",
                access: .readWrite),
        ]
        var containerEnvironment = [
            "CCACHE_BASEDIR": "/",
            "CCACHE_DIR": "/ccache",
        ]
        if let jobs = configuration.environment["NUCLEUS_BUILD_JOBS"],
            !jobs.isEmpty
        {
            containerEnvironment["NUCLEUS_BUILD_JOBS"] = jobs
        }
        return TaskDeclaration(
            id: TaskID(rawValue: "toolchain.build-linux-amd64-runtime"),
            component: component,
            dependencies: [builder.id, sysroot.id],
            inputs: [
                .dependencyOutput(configuration.runtimeBuilderImageID),
                .dependencyOutput(configuration.linuxSysroot),
                .file(
                    configuration.lockFile.removingLastComponent().appending(
                        "nucleus-target-runtime-presets.ini")),
                .value(name: "swift-source-gitlinks", bytes: Array(configuration.sourceID.utf8)),
            ],
            outputs: [
                OutputDeclaration(path: runtimeLibrary, validation: .regularFile)
            ],
            locks: [.checkout("swift-linux-amd64-runtime")],
            cachePolicy: .contentAddressed,
            operation: .sequence([
                .removePath(configuration.runtimeInstall),
                .createDirectory(configuration.runtimeInstall),
                .createDirectory(configuration.runtimeBuildWorkspace),
                .createDirectory(configuration.runtimeCompilerCache),
                .runOCI(
                    OCIExecution(
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxX86_64,
                        imageID: configuration.runtimeBuilderImageID,
                        hostname: "swift-linux-amd64-runtime",
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
            id: TaskID(rawValue: "toolchain.build-sdk-generator"),
            component: component,
            inputs: [
                .tree(configuration.generatorSource),
                .file(configuration.lockFile),
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
        runtime: TaskDeclaration
    ) -> TaskDeclaration {
        let expandedHost = configuration.candidate.appending("host-package")
        let hostPayload = expandedHost.appending(
            "\(configuration.lock.snapshot)-osx-package.pkg/Payload")
        let hostToolchain = configuration.candidate.appending("toolchain")
        let generatedLinux = configuration.candidate.appending("generated-linux")
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let androidBundle = "\(configuration.lock.androidBundleID).artifactbundle"
        let linuxBundle = "\(configuration.lock.linuxBundleID).artifactbundle"
        let generatedLinuxSDK = generatedLinux.appending(
            "Bundles/\(linuxBundle)/\(configuration.lock.linuxBundleID)/"
                + "x86_64-unknown-linux-gnu/ubuntu-noble.sdk")
        let generatorExecutable = generator.outputs[0].path

        var generatorArguments = [
            "make-linux-sdk",
            "--no-host-toolchain",
            "--target", "x86_64-unknown-linux-gnu",
            "--distribution-name", "ubuntu",
            "--distribution-version", "24.04",
            "--swift-version", configuration.lock.snapshot,
            "--target-swift-package-path", configuration.runtimeInstall.string,
            "--sdk-name", configuration.lock.linuxBundleID,
            "--bundle-version", configuration.lock.snapshot,
            "--output-path", generatedLinux.string,
        ]
        for package in downloads.ubuntu {
            generatorArguments += ["--target-system-package-path", package.string]
        }

        var hostEnvironment = configuration.environment
        hostEnvironment["ANDROID_NDK_HOME"] = configuration.ndkRoot.string
        hostEnvironment.removeValue(forKey: "SWIFTCI_USE_LOCAL_DEPS")

        let operations: [TaskOperation] = [
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
                        configuration.runtimeInstall.appending("usr").string,
                        generatedLinuxSDK.appending("usr").string,
                    ],
                    workingDirectory: configuration.candidate,
                    environment: hostEnvironment,
                    output: .logged)),
            .createDirectory(sdkRoot),
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
            .command(
                CommandSpec(
                    executable: .path(FilePath("/bin/mv")),
                    arguments: [
                        generatedLinux.appending("Bundles/\(linuxBundle)").string,
                        sdkRoot.appending(linuxBundle).string,
                    ],
                    workingDirectory: configuration.candidate,
                    environment: hostEnvironment,
                    output: .logged)),
            .writeFile(
                configuration.candidate.appending(".nucleus-target-sdk-generation"),
                bytes: Array(configuration.lock.snapshot.utf8)),
        ]

        return TaskDeclaration(
            id: TaskID(rawValue: "toolchain.assemble-target-sdks"),
            component: component,
            dependencies: downloads.tasks.map(\.id) + [generator.id, runtime.id],
            inputs: [
                .file(configuration.lockFile),
                .file(configuration.ndkRoot.appending("source.properties")),
            ] + downloads.tasks.map { .dependencyOutput($0.outputs[0].path) }
                + [
                    .dependencyOutput(generatorExecutable),
                    .dependencyOutput(runtime.outputs[0].path),
                ],
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

    private static func validationTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        assembly: TaskDeclaration
    ) -> TaskDeclaration {
        let hostSwift = assembly.outputs[0].path
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let validationRoot = configuration.candidate.appending("validation")
        let linuxBuild = validationRoot.appending("linux-amd64")
        let androidARM64Build = validationRoot.appending("android-arm64")
        let androidAMD64Build = validationRoot.appending("android-amd64")
        let linuxExecutable = linuxBuild.appending(
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
            id: TaskID(rawValue: "toolchain.validate-target-sdks"),
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
                OutputDeclaration(path: linuxExecutable, validation: .executableFile),
                OutputDeclaration(
                    path: androidARM64Executable, validation: .executableFile),
                OutputDeclaration(
                    path: androidAMD64Executable, validation: .executableFile),
            ],
            operation: .sequence([
                .createDirectory(validationRoot),
                build(
                    linuxBuild,
                    sdk: configuration.lock.linuxBundleID,
                    triple: "x86_64-unknown-linux-gnu"),
                build(
                    androidARM64Build,
                    sdk: configuration.lock.androidBundleID,
                    triple:
                        "aarch64-unknown-linux-android\(configuration.lock.androidAPILevel)"),
                build(
                    androidAMD64Build,
                    sdk: configuration.lock.androidBundleID,
                    triple:
                        "x86_64-unknown-linux-android\(configuration.lock.androidAPILevel)"),
                .command(
                    CommandSpec(
                        executable: .path(configuration.validator),
                        arguments: [
                            assembly.outputs[1].path.string,
                            linuxExecutable.string,
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
            id: TaskID(rawValue: "toolchain.activate-target-sdks"),
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
        [configuration.lock.linuxBundleID, configuration.lock.androidBundleID]
            .map { bundleID in
                let name = "\(bundleID).artifactbundle"
                let link = configuration.sdkDiscoveryRoot.appending(name)
                let target = configuration.generation.appending(
                    "swift-sdks/\(name)")
                return TaskDeclaration(
                    id: TaskID(rawValue: "toolchain.discover-\(bundleID)"),
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
