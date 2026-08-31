import ColliderCore
import ContainerizationArchive
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

public struct SwiftTargetSDKStoragePaths: Equatable, Sendable {
    public let cacheRoot: FilePath
    public let artifactRoot: FilePath
    public let downloadRoot: FilePath
    public let generatorScratch: FilePath
    public let rebuildLock: FilePath

    public init(cacheRoot: FilePath, hostBuildRoot: FilePath) {
        self.cacheRoot = cacheRoot
        artifactRoot = cacheRoot.appending("swift-target-sdks")
        downloadRoot = cacheRoot.appending("downloads/swift-target-sdks")
        generatorScratch = hostBuildRoot.appending("work/swift-sdk-generator")
        rebuildLock = hostBuildRoot.appending(
            "state/locks/swift-target-sdk-rebuild.lock")
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

    /// One Ubuntu package, named by where it sits in the archive pool rather
    /// than by a URL.
    ///
    /// A pool path holds exactly the current version of a package and loses the
    /// file when a new one publishes, so every package resolves through a
    /// snapshot timestamp instead. That timestamp is one decision about which
    /// archive this SDK is built from, and repeating it in 208 URLs made it 208
    /// decisions that could disagree -- which is what the builder image already
    /// did, installing from two snapshots at once. The package states the part
    /// that is its own and the inputs state the part they share.
    public struct UbuntuPackage: Codable, Equatable, Sendable {
        /// The package's location under the archive root, `pool/...`.
        public let path: String
        public let sha256: String

        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256
        }

        public var fileName: String {
            String(path.split(separator: "/").last ?? "")
        }
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
    /// The `snapshot.ubuntu.com` timestamp every Ubuntu package resolves
    /// through.
    public let ubuntuSnapshot: String

    /// Where a package is fetched from, for this snapshot.
    public func url(for package: UbuntuPackage) -> String {
        "https://snapshot.ubuntu.com/ubuntu/\(ubuntuSnapshot)/\(package.path)"
    }

    public var androidBundleID: String { "\(snapshot)_android" }
    public var linuxBundleID: String { "nucleus-swift-6.4-linux" }

    public static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct SwiftLinuxTargetBuildConfiguration: Sendable {
    public let target: SwiftTargetSDKInputs.LinuxTarget
    public let runtimeBuildWorkspace: PersistentWorkspaceDeclaration
    public let runtimeCompilerCacheWorkspace: PersistentWorkspaceDeclaration
    public let runtimeInstall: FilePath
    public let sysroot: FilePath

    public init(
        target: SwiftTargetSDKInputs.LinuxTarget,
        runtimeBuildWorkspace: PersistentWorkspaceDeclaration,
        runtimeCompilerCacheWorkspace: PersistentWorkspaceDeclaration,
        runtimeInstall: FilePath,
        sysroot: FilePath
    ) {
        self.target = target
        self.runtimeBuildWorkspace = runtimeBuildWorkspace
        self.runtimeCompilerCacheWorkspace = runtimeCompilerCacheWorkspace
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
    public let runtimeBuilderBaseImage: ArtifactReference
    public let linuxTargets: [SwiftLinuxTargetBuildConfiguration]
    public let pkgConfigDirectory: FilePath
    public let candidate: FilePath
    public let generation: FilePath
    public let active: FilePath
    /// Where the native-sysroot facet is published, named by a digest over
    /// what determines the native half alone.
    public let nativeSysroot: FilePath
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
        runtimeBuilderBaseImage: ArtifactReference,
        linuxTargets: [SwiftLinuxTargetBuildConfiguration],
        pkgConfigDirectory: FilePath,
        candidate: FilePath,
        generation: FilePath,
        active: FilePath,
        nativeSysroot: FilePath,
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
        self.runtimeBuilderBaseImage = runtimeBuilderBaseImage
        self.linuxTargets = linuxTargets
        self.pkgConfigDirectory = pkgConfigDirectory
        self.candidate = candidate
        self.generation = generation
        self.active = active
        self.nativeSysroot = nativeSysroot
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
    public let activeSDK: ArtifactReference
    public let activeSwift: ExecutableReference
    public let nativeSysroot: ArtifactReference
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
        package let activeSDK: ArtifactReference
        package let activeSwift: ExecutableReference
        package let nativeSysroot: ArtifactReference
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
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        reuseActiveGeneration: Bool = true
    ) throws -> PreparedComponent {
        if reuseActiveGeneration,
            activeGenerationIsReusable(configuration)
        {
            return try reusableActiveGeneration(configuration)
        }
        let taskSet = try generation(configuration)
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: taskSet.tasks,
            entrypoints: [
                ComponentEntrypoint(
                    id: .build,
                    roots: Set(taskSet.selected))
            ],
            storage: storage(configuration, tasks: taskSet.tasks))
        return PreparedComponent(
            component: component,
            activeSDK: taskSet.activeSDK,
            activeSwift: taskSet.activeSwift,
            nativeSysroot: taskSet.nativeSysroot)
    }

    package static func activeGenerationIsReusable(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) -> Bool {
        let activeURL = URL(fileURLWithPath: configuration.active.string)
        let resolvedActive = activeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let expectedGeneration = URL(fileURLWithPath: configuration.generation.string)
            .standardizedFileURL.path
        guard resolvedActive == expectedGeneration else { return false }
        let fileManager = FileManager.default
        return fileManager.fileExists(
            atPath: configuration.active.appending("swift-sdks").string)
            && fileManager.fileExists(
                atPath: configuration.active.appending("toolchain/usr/bin/swift").string)
            && fileManager.fileExists(
                atPath: configuration.generation.appending(
                    ".nucleus-target-sdk-generation"
                ).string)
    }

    private static func reusableActiveGeneration(
        _ configuration: SwiftTargetSDKGenerationConfiguration
    ) throws -> PreparedComponent {
        let activation = try activationTask(configuration)
        let task = activation.task
        let discoveries = try discoveryTasks(
            configuration,
            activation: activation)
        let ready = try readyTask(
            configuration,
            activation: activation,
            discoveries: discoveries)
        let facet = try nativeSysrootTask(configuration, ready: ready)
        let tasks = [task] + discoveries.map(\.task) + [ready.task, facet.task]
        return PreparedComponent(
            component: try ComponentDefinition(
                descriptor: descriptor,
                tasks: tasks,
                entrypoints: [
                    ComponentEntrypoint(
                        id: .build,
                        roots: [ready.task.id, facet.task.id])
                ],
                storage: storage(configuration, tasks: tasks)),
            activeSDK: ready.activeSDK,
            activeSwift: ready.activeSwift,
            nativeSysroot: facet.root)
    }

    /// Publishes the native half of the active sysroot under its own identity.
    ///
    /// Every C and C++ consumer reads the sysroot and nothing else out of the
    /// SDK, so pointing them at the whole bundle makes a change to the Swift
    /// half -- or to an input that touches neither half -- re-key builds that
    /// contain no Swift. This task's output path is named by a digest over what
    /// determines the native content alone, so its identity holds across every
    /// other change.
    ///
    /// It runs every time and re-points at whichever generation is active,
    /// which is what keeps the facet current while its identity stays put: the
    /// two are independent exactly as Phase 1 requires of an always-run task.
    private static func nativeSysrootTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        ready: ReadyArtifact
    ) throws -> NativeSysrootArtifact {
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.publish-native-sysroot"),
            component: component)
        builder.after(ready.activeSDK.ordering)
        let root: ArtifactReference = try builder.output(
            "native-sysroot",
            path: configuration.nativeSysroot,
            validation: .symlinkTarget)
        let task = builder.build(
            postconditions: [
                PathPostcondition(
                    path: configuration.nativeSysroot,
                    validation: .symlinkTarget)
            ],
            locks: [
                .shared(configuration.active.removingLastComponent().appending("rebuild.lock"))
            ],
            assessmentPolicy: .always,
            action: try AnyColliderAction(
                PublishNativeSysrootAction(
                    activeSDK: configuration.active.appending("swift-sdks"),
                    facet: configuration.nativeSysroot)))
        return NativeSysrootArtifact(task: task, root: root)
    }

    private static func storage(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        tasks: [TaskDeclaration]
    ) -> [StorageDeclaration] {
        let artifactRoot = configuration.active.removingLastComponent()
        let runtimeInputs = artifactRoot.appending("runtime-inputs")
        func producers(_ matches: (String) -> Bool, runtime: String) -> Set<StorageProducer> {
            let resolved = Set(
                tasks.compactMap { matches($0.id.rawValue) ? StorageProducer.task($0.id) : nil })
            return resolved.isEmpty ? [.runtime(runtime)] : resolved
        }
        func writableProducers(
            in root: FilePath,
            runtime: String
        ) -> Set<StorageProducer> {
            let containment = FilePathContainmentRoot(root)
            let resolved: Set<StorageProducer> = Set(
                tasks.compactMap { task -> StorageProducer? in
                    let writesRoot =
                        task.action?.requirements.effects.contains {
                            $0.access != .read && containment.contains($0.scope.root)
                        } == true
                    return writesRoot ? .task(task.id) : nil
                })
            return resolved.isEmpty ? [.runtime(runtime)] : resolved
        }

        return [
            StorageDeclaration(
                id: "swift-target-sdk-discovery",
                owner: descriptor.id,
                producers: producers(
                    { $0.hasPrefix("swift-sdk.discover-") },
                    runtime: "swift-sdk-discovery"),
                storageClass: .published,
                root: configuration.sdkDiscoveryRoot,
                safetyRoot: configuration.sdkDiscoveryRoot.removingLastComponent(),
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "swift-target-sdk-displaced-discovery",
                owner: descriptor.id,
                producers: producers(
                    { $0.hasPrefix("swift-sdk.discover-") },
                    runtime: "swift-sdk-discovery"),
                storageClass: .published,
                root: configuration.displacedRoot,
                safetyRoot: configuration.displacedRoot.removingLastComponent(),
                retentionPolicy: .protected),
            StorageDeclaration(
                id: "swift-target-sdk-active",
                owner: descriptor.id,
                producers: producers(
                    { $0 == "swift-sdk.activate-target-sdks" },
                    runtime: "swift-sdk-generation-lifecycle"),
                storageClass: .published,
                root: configuration.active,
                safetyRoot: artifactRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "swift-target-sdk-native-sysroots",
                owner: descriptor.id,
                producers: producers(
                    { $0 == "swift-sdk.publish-native-sysroot" },
                    runtime: "swift-sdk-generation-lifecycle"),
                storageClass: .published,
                root: configuration.nativeSysroot.removingLastComponent(),
                safetyRoot: artifactRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "swift-target-sdk-runtime-inputs",
                owner: descriptor.id,
                producers: writableProducers(
                    in: runtimeInputs,
                    runtime: "swift-sdk-runtime-inputs"),
                storageClass: .incremental,
                root: runtimeInputs,
                safetyRoot: artifactRoot,
                retentionPolicy: .singleWorkingSet),
            StorageDeclaration(
                id: "swift-target-sdk-generations",
                owner: descriptor.id,
                producers: writableProducers(
                    in: artifactRoot.appending("generations"),
                    runtime: "swift-sdk-generation-lifecycle"),
                storageClass: .generation,
                root: artifactRoot.appending("generations"),
                safetyRoot: artifactRoot,
                retentionPolicy: .keepActiveAndRollback(count: 0),
                activeGenerationLink: configuration.active,
                generationNaming: .contentIdentity,
                // The candidate is named for the artifact identity alone, so
                // a pattern expecting a timestamp and a process could never
                // match one and retention never reclaimed an interrupted
                // build's leftovers.
                interruptedCandidateNaming: DirectoryNamePattern(
                    rawValue: #"^\.candidate-[0-9a-f]{24}$"#)),
            StorageDeclaration(
                id: "swift-sdk-generator-build",
                owner: descriptor.id,
                producers: producers(
                    { $0 == "swift-sdk.build-sdk-generator" },
                    runtime: "swift-sdk-rebuild"),
                storageClass: .incremental,
                root: configuration.generatorScratch,
                safetyRoot: configuration.generatorScratch.removingLastComponent(),
                retentionPolicy: .singleWorkingSet),
        ]
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
        let sanitizedPackages = try downloads.linux.map {
            try sanitizeLinuxPackagesTask(configuration, downloads: $0)
        }
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
                builderImage: configuration.runtimeBuilderBaseImage,
                sysroot: sysroot.artifact)
        }
        let generator = try generatorTask(configuration)
        let assembly = try assemblyTask(
            configuration,
            downloads: downloads,
            sanitizedPackages: sanitizedPackages,
            generator: generator,
            runtimes: runtimes)
        let validation = try validationTasks(configuration, assembly: assembly)
        let activation = try activationTask(configuration, after: validation)
        let discoveries = try discoveryTasks(configuration, activation: activation)
        let ready = try readyTask(
            configuration,
            activation: activation,
            discoveries: discoveries)
        let facet = try nativeSysrootTask(configuration, ready: ready)

        let tasks =
            downloads.tasks
            + sanitizedPackages.map(\.task)
            + sysroots.map(\.task) + runtimes.map(\.task)
            + [generator.task, assembly.task] + validation.tasks + [activation.task]
            + discoveries.map(\.task)
            + [ready.task, facet.task]
        return SwiftTargetSDKTaskSet(
            tasks: tasks,
            selected: [ready.task.id, facet.task.id],
            activeSDK: ready.activeSDK,
            activeSwift: ready.activeSwift,
            nativeSysroot: facet.root)
    }

    private struct Downloads {
        let host: DownloadArtifact
        let android: DownloadArtifact
        let linux: [LinuxDownloads]

        var tasks: [TaskDeclaration] {
            [host.task, android.task] + linux.flatMap(\.tasks)
        }

        var artifacts: [ArtifactReference] {
            [host.artifact, android.artifact] + linux.flatMap(\.allPackages)
        }
    }

    private struct DownloadArtifact {
        let task: TaskDeclaration
        let artifact: ArtifactReference
    }

    private struct SysrootArtifact {
        let task: TaskDeclaration
        let artifact: ArtifactReference
    }

    private struct RuntimeArtifact {
        let task: TaskDeclaration
        let install: ArtifactReference
    }

    private struct GeneratorArtifact {
        let task: TaskDeclaration
        let executable: ExecutableReference
    }

    private struct AssemblyArtifacts {
        let task: TaskDeclaration
        let hostSwift: ExecutableReference
        let linuxSDK: ArtifactReference
        let androidSDK: ArtifactReference
    }

    private struct ValidationArtifacts {
        let tasks: [TaskDeclaration]
        let marker: ArtifactReference
    }

    private struct ActivationArtifact {
        let task: TaskDeclaration
        let generationMarker: ArtifactReference
    }

    private struct ReadyArtifact {
        let task: TaskDeclaration
        let activeSDK: ArtifactReference
        let activeSwift: ExecutableReference
    }

    private struct NativeSysrootArtifact {
        let task: TaskDeclaration
        let root: ArtifactReference
    }

    private struct DiscoveryArtifact {
        let task: TaskDeclaration
        let link: ArtifactReference
    }

    private struct LinuxDownloads {
        let architecture: SwiftTargetSDKInputs.LinuxArchitecture
        let runtimePackages: [DownloadArtifact]
        let sdkPackages: [DownloadArtifact]

        var tasks: [TaskDeclaration] {
            (runtimePackages + sdkPackages).map(\.task)
        }

        var allPackages: [ArtifactReference] {
            (runtimePackages + sdkPackages).map(\.artifact)
        }
    }

    private struct SanitizedLinuxPackages {
        let architecture: SwiftTargetSDKInputs.LinuxArchitecture
        let task: TaskDeclaration
        let packages: [ArtifactReference]
    }

    private static func validate(_ inputs: SwiftTargetSDKInputs) throws {
        guard !inputs.snapshot.isEmpty,
            !inputs.ubuntuSnapshot.isEmpty,
            inputs.linuxTargets.allSatisfy({
                $0.allUbuntuPackages.allSatisfy { $0.path.hasPrefix("pool/") }
            }),
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
                    try downloadTask(
                        id:
                            "swift-sdk.download-ubuntu-\(target.architecture.rawValue)-\(role)-\(index)",
                        input: SwiftTargetSDKInputs.Input(
                            maximumResponseSize: 32 * 1_024 * 1_024,
                            sha256: package.sha256,
                            url: configuration.inputs.url(for: package)),
                        destination: configuration.downloadRoot.appending(
                            "ubuntu/\(target.architecture.rawValue)/\(package.fileName)"))
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
        let artifact: ArtifactReference = try builder.output(
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

    private static func sanitizeLinuxPackagesTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        downloads: LinuxDownloads
    ) throws -> SanitizedLinuxPackages {
        let inputs = downloads.allPackages
        let outputRoot = configuration.downloadRoot.appending(
            "sanitized/\(downloads.architecture.rawValue)")
        var builder = TaskBuilder(
            id: TaskID(
                rawValue:
                    "swift-sdk.sanitize-ubuntu-\(downloads.architecture.rawValue)-packages"),
            component: component)
        for input in inputs {
            builder.consume(input)
        }
        let outputs: [ArtifactReference] = try inputs.enumerated().map {
            index, _ in
            try builder.output(
                OutputSlotID(rawValue: "package-\(index)"),
                path: outputRoot.appending("package-\(index).deb"),
                validation: .regularFile)
        }
        let task = builder.build(
            inputs: [],
            assessmentPolicy: .incremental,
            action: try AnyColliderAction(
                SanitizeLinuxSDKPackagesAction(
                    inputs: inputs.map(\.path),
                    outputRoot: outputRoot,
                    outputs: outputs.map(\.path),
                    environment: configuration.environment)))
        return SanitizedLinuxPackages(
            architecture: downloads.architecture,
            task: task,
            packages: outputs)
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
        let artifact: ArtifactReference = try builder.output(
            "sysroot",
            path: target.sysroot,
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [],
            locks: [.checkout("swift-linux-\(architecture.rawValue)-runtime-inputs")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    PrepareLinuxSysrootAction(
                        sysroot: target.sysroot,
                        architecture: architecture.gnuArchitecture,
                        packages: downloads.runtimePackages.map(\.artifact.path),
                        environment: configuration.environment)))
        return SysrootArtifact(task: task, artifact: artifact)
    }

    private static func linuxRuntimeTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        target: SwiftLinuxTargetBuildConfiguration,
        builderImage: ArtifactReference,
        sysroot: ArtifactReference
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
                source: configuration.runtimeBuilderContext,
                target: "/runtime-builder",
                access: .readOnly),
            OCIMount(
                source: target.sysroot,
                target: "/target-sysroot",
                access: .readOnly),
            OCIMount(
                boundedExport: target.runtimeInstall,
                target: "/output"),
        ]
        var containerEnvironment = [
            "CCACHE_BASEDIR": "/",
            "CCACHE_DIR": "/ccache",
            "LD_LIBRARY_PATH":
                "/opt/swift/usr/lib/swift/linux:/opt/swift-compat/arm64",
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
        taskBuilder.consume(builderImage)
        let install: ArtifactReference = try taskBuilder.output(
            "runtime-install",
            path: target.runtimeInstall,
            validation: .nonEmptyDirectory)
        let _: ArtifactReference = try taskBuilder.output(
            "swift-core-runtime",
            path: runtimeLibrary,
            validation: .regularFile)
        let _: ArtifactReference = try taskBuilder.output(
            "swift-testing-module",
            path: swiftTestingModule,
            validation: .regularFile)
        let _: ArtifactReference = try taskBuilder.output(
            "swift-testing-runtime",
            path: swiftTestingLibrary,
            validation: .regularFile)
        let task = taskBuilder.build(
            inputs: [
                .file(
                    configuration.inputsFile.removingLastComponent().appending(
                        "nucleus-target-runtime-presets.ini")),
                .file(
                    configuration.runtimeBuilderContext.appending(
                        "entrypoint.sh")),
                .file(
                    configuration.runtimeBuilderContext.appending(
                        "nucleus-target-swiftc")),
                .string(name: "swift-source-gitlinks", value: configuration.sourceID),
            ],
            locks: [.checkout("swift-linux-\(architecture.rawValue)-runtime")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    BuildSwiftLinuxRuntimeAction(
                        install: target.runtimeInstall,
                        execution: OCIExecution(
                            executionPlatform: .linuxARM64OCI,
                            artifactTarget: architecture.artifactTarget,
                            imageID: builderImage.path,
                            hostname: "swift-linux-\(architecture.rawValue)-runtime",
                            workingDirectory: "/src",
                            hostWorkingDirectory: configuration.sourceWorkspace,
                            mounts: mounts,
                            persistentWorkspaceMounts: [
                                OCIPersistentWorkspaceMount(
                                    workspace: target.runtimeBuildWorkspace,
                                    target: "/build",
                                    access: .readWrite),
                                OCIPersistentWorkspaceMount(
                                    workspace: target.runtimeCompilerCacheWorkspace,
                                    target: "/ccache",
                                    access: .readWrite),
                            ],
                            userPolicy: .builder,
                            capabilityPolicy: .dropAll,
                            privilegePolicy: .prohibitAcquisition,
                            processFilesystemPolicy: .standard,
                            resourceLimits: .parallelBuild,
                            containerEnvironment: containerEnvironment,
                            imageEntrypointOverride: "/runtime-builder/entrypoint.sh",
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
        let artifact: ExecutableReference = try builder.executableOutput(
            "executable",
            path: executable)
        let task = builder.build(
            inputs: [
                .sourceCheckout(configuration.generatorSource),
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
        sanitizedPackages: [SanitizedLinuxPackages],
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
            guard
                let targetPackages = sanitizedPackages.first(where: {
                    $0.architecture == architecture
                })
            else {
                throw SwiftTargetSDKRecipeFailure.invalidInput(
                    "missing sanitized Linux packages for \(architecture.rawValue)")
            }
            assemblyTargets.append(
                SwiftSDKAssemblyTarget(
                    architecture: architecture.rawValue,
                    gnuArchitecture: architecture.gnuArchitecture,
                    triple: architecture.triple,
                    runtimeInstall: target.runtimeInstall,
                    packages: targetPackages.packages.map(\.path)))
        }
        let manifest = try linuxArtifactBundleManifest(configuration.inputs)
        let metadata = try linuxSwiftSDKMetadata(configuration.inputs)

        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.assemble-target-sdks"),
            component: component)
        for artifact in downloads.artifacts {
            builder.consume(artifact)
        }
        for packages in sanitizedPackages {
            for artifact in packages.packages {
                builder.consume(artifact)
            }
        }
        builder.consume(generator.executable)
        for runtime in runtimes {
            builder.consume(runtime.install)
        }
        let hostSwift: ExecutableReference = try builder.executableOutput(
            "host-swift",
            path: hostToolchain.appending("usr/bin/swift"))
        let linuxSDK: ArtifactReference = try builder.output(
            "linux-sdk",
            path: sdkRoot.appending(linuxBundle),
            validation: .nonEmptyDirectory)
        let androidSDK: ArtifactReference = try builder.output(
            "android-sdk",
            path: sdkRoot.appending(androidBundle),
            validation: .nonEmptyDirectory)
        let task = builder.build(
            inputs: [
                .file(configuration.inputsFile),
                .file(configuration.ndkRoot.appending("source.properties")),
                .sourceCheckout(configuration.pkgConfigDirectory),
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
                        pkgConfigDirectory: configuration.pkgConfigDirectory,
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
            let sdkRoot =
                "\(triple)/\(NucleusLinuxABI.sdkDirectoryName)"
            targetTriples[triple] = [
                "sdkRootPath": sdkRoot,
                "librarySearchPaths": [
                    "\(sdkRoot)/usr/lib/swift/linux",
                    "\(sdkRoot)/usr/lib/\(target.architecture.gnuArchitecture)",
                ],
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

    private static func validationTasks(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        assembly: AssemblyArtifacts
    ) throws -> ValidationArtifacts {
        let hostSwift = assembly.hostSwift.path
        let hostLinker = hostSwift.removingLastComponent().appending("ld.lld")
        let sdkRoot = configuration.candidate.appending("swift-sdks")
        let validationRoot = configuration.candidate.appending("validation")
        let hostToolsetBytes = try jsonBytes([
            "schemaVersion": "1.0",
            "linker": ["path": hostLinker.string],
        ])
        let productsRoot = validationRoot.appending("products")
        var environment = configuration.environment
        environment["ANDROID_NDK_HOME"] = configuration.ndkRoot.string

        let targets:
            [(
                id: String,
                sdk: String,
                triple: String,
                sdkArtifact: ArtifactReference
            )] = [
                (
                    "linux-arm64",
                    configuration.inputs.linuxBundleID,
                    "aarch64-unknown-linux-gnu",
                    assembly.linuxSDK
                ),
                (
                    "linux-x86_64",
                    configuration.inputs.linuxBundleID,
                    "x86_64-unknown-linux-gnu",
                    assembly.linuxSDK
                ),
                (
                    "android-arm64",
                    configuration.inputs.androidBundleID,
                    "aarch64-unknown-linux-android\(configuration.androidAPILevel)",
                    assembly.androidSDK
                ),
                (
                    "android-amd64",
                    configuration.inputs.androidBundleID,
                    "x86_64-unknown-linux-android\(configuration.androidAPILevel)",
                    assembly.androidSDK
                ),
            ]
        var tasks: [TaskDeclaration] = []
        var executables: [ExecutableReference] = []
        for target in targets {
            let scratch = validationRoot.appending(target.id)
            let executablePath = productsRoot.appending(target.id).appending("hello")
            var builder = TaskBuilder(
                id: TaskID(rawValue: "swift-sdk.validate-\(target.id)-consumer"),
                component: component)
            builder.consume(assembly.hostSwift)
            builder.consume(target.sdkArtifact)
            let executable: ExecutableReference = try builder.executableOutput(
                "executable",
                path: executablePath)
            tasks.append(
                builder.build(
                    inputs: [.sourceCheckout(configuration.validationFixture)],
                    locks: [.checkout("swift-target-sdk-generations")],
                    action: try AnyColliderAction(
                        ValidateSwiftTargetSDKConsumerAction(
                            hostSwift: hostSwift,
                            hostToolset: scratch.appending("host-toolset.json"),
                            hostToolsetBytes: hostToolsetBytes,
                            sdkRoot: sdkRoot,
                            scratch: scratch,
                            fixture: configuration.validationFixture,
                            ndkRoot: configuration.ndkRoot,
                            sdk: target.sdk,
                            triple: target.triple,
                            executable: executablePath,
                            environment: environment))))
            executables.append(executable)
        }

        var verificationBuilder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.validate-target-sdks"),
            component: component)
        verificationBuilder.consume(assembly.linuxSDK)
        for executable in executables {
            verificationBuilder.consume(executable)
        }
        let marker: ArtifactReference = try verificationBuilder.output(
            "validation-marker",
            path: validationRoot.appending(".validated"),
            validation: .regularFile)
        tasks.append(
            verificationBuilder.build(
                inputs: [.file(configuration.validator)],
                locks: [.checkout("swift-target-sdk-generations")],
                action: try AnyColliderAction(
                    ValidateSwiftTargetSDKArtifactsAction(
                        linuxSDK: assembly.linuxSDK.path,
                        validationRoot: validationRoot,
                        validator: configuration.validator,
                        linuxSDKDirectoryName: NucleusLinuxABI.sdkDirectoryName,
                        minimumGlibcVersion: NucleusLinuxABI.minimumGlibcVersion,
                        executablePaths: executables.map(\.path),
                        marker: marker.path,
                        environment: environment))))
        return ValidationArtifacts(tasks: tasks, marker: marker)
    }

    /// The task that asserts which generation is the active Swift SDK.
    ///
    /// One generation has one identity, whichever path established it. The
    /// generation directory is named by a digest over everything that defines
    /// it -- the pinned inputs, the generator source, the validator, the NDK
    /// and host toolchain -- so that name, carried here by the marker's output
    /// path, is what identifies the assertion. Producing the generation in this
    /// run rather than finding it already published is a difference in the work
    /// the run had to do, not in which SDK is active.
    ///
    /// The generation subgraph is therefore ordered before this task rather
    /// than consumed by it. Consuming it made the marker's recorded identity
    /// depend on whether the run built the generation or reused it, and every
    /// consumer of the SDK re-executed on each alternation while the toolchain
    /// on disk never changed.
    private static func activationTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        after validation: ValidationArtifacts? = nil
    ) throws -> ActivationArtifact {
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.activate-target-sdks"),
            component: component)
        if let validation {
            builder.after(validation.marker.ordering)
        }
        let marker: ArtifactReference = try builder.output(
            "generation-marker",
            path: configuration.generation.appending(
                ".nucleus-target-sdk-generation"),
            validation: .regularFile)
        let task = builder.build(
            inputs: [.file(configuration.inputsFile)],
            postconditions: [
                PathPostcondition(
                    path: configuration.active,
                    validation: .symlinkTarget)
            ],
            locks: [
                .shared(configuration.active.removingLastComponent().appending("rebuild.lock"))
            ],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    ActivateSwiftSDKGenerationAction(
                        candidate: configuration.candidate,
                        generation: configuration.generation,
                        active: configuration.active)))
        return ActivationArtifact(
            task: task,
            generationMarker: marker)
    }

    private static func discoveryTasks(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        activation: ActivationArtifact
    ) throws -> [DiscoveryArtifact] {
        try [configuration.inputs.linuxBundleID, configuration.inputs.androidBundleID]
            .map { bundleID in
                let name = "\(bundleID).artifactbundle"
                let link = configuration.sdkDiscoveryRoot.appending(name)
                let target = configuration.active.appending(
                    "swift-sdks/\(name)")
                var builder = TaskBuilder(
                    id: TaskID(rawValue: "swift-sdk.discover-\(bundleID)"),
                    component: component)
                builder.consume(activation.generationMarker)
                let artifact: ArtifactReference = try builder.output(
                    "discovery-link",
                    path: link,
                    validation: .symlinkTarget)
                let task = builder.build(
                    postconditions: [
                        PathPostcondition(path: link, validation: .symlinkTarget)
                    ],
                    locks: [.checkout("swift-target-sdk-discovery")],
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

    private static func readyTask(
        _ configuration: SwiftTargetSDKGenerationConfiguration,
        activation: ActivationArtifact,
        discoveries: [DiscoveryArtifact]
    ) throws -> ReadyArtifact {
        var builder = TaskBuilder(
            id: TaskID(rawValue: "swift-sdk.publish-active-generation"),
            component: component)
        builder.consume(activation.generationMarker)
        for discovery in discoveries {
            builder.consume(discovery.link)
        }
        let activeSDK: ArtifactReference = try builder.output(
            "active-sdk",
            path: configuration.active.appending("swift-sdks"),
            validation: .nonEmptyDirectory)
        let activeSwift: ExecutableReference = try builder.executableOutput(
            "active-swift",
            path: configuration.active.appending("toolchain/usr/bin/swift"))
        return ReadyArtifact(
            task: builder.build(recordsActiveArtifact: true),
            activeSDK: activeSDK,
            activeSwift: activeSwift)
    }

    private static func fileName(from value: String) throws -> String {
        guard let url = URL(string: value), !url.lastPathComponent.isEmpty else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "download URL has no file name: \(value)")
        }
        return url.lastPathComponent
    }
}

private struct BuildSwiftLinuxRuntimeAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let install: FilePath
        let execution: OCIExecution

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: install)
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    static let kind: ActionKind = "swift-sdk.build-linux-runtime"

    let install: FilePath
    let execution: OCIExecution

    var identity: Identity {
        Identity(
            install: install,
            execution: execution)
    }

    var requirements: ActionRequirements {
        ociActionRequirements(execution: execution)
    }

    var environment: [String: String] { execution.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(install)
        try context.files.createDirectory(install)
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
        return ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(identity.destination))
            ],
            networkAccess: .contentAddressed,
            executionPlatform: .macOSARM64Native)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: candidate)
            encoder.append(path: generation)
            encoder.append(path: active)
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
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(candidate)),
                // Read as well as write: whether a candidate was staged decides
                // whether this generation still has to be published.
                ActionEffect(.readWrite, scope: .output(generation)),
                ActionEffect(.write, scope: .publication(active)),
            ], executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        // A run that found this generation already published staged no
        // candidate, so the assertion this action makes is already true. The
        // generation's own marker is what proves it, and requiring it keeps a
        // genuinely missing candidate an error rather than a silent success.
        guard try context.files.metadata(for: candidate)?.type == .directory else {
            let published = generation.appending(".nucleus-target-sdk-generation")
            guard try context.files.metadata(for: published)?.type == .regular else {
                throw SwiftTargetSDKRecipeFailure.invalidInput(
                    "no target SDK candidate at \(candidate), and \(generation) "
                        + "has no generation marker to activate")
            }
            return
        }
        let marker = candidate.appending(".nucleus-target-sdk-generation")
        guard try context.files.metadata(for: marker)?.type == .regular else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "target SDK candidate has no generation marker at \(marker)")
        }
        for stagingDirectory in [
            "generated-linux", "host-package", "host-payload", "validation",
        ] {
            try context.files.remove(candidate.appending(stagingDirectory))
        }
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generation,
            active: active)
    }
}

private struct PublishNativeSysrootAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let activeSDK: FilePath
        let facet: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: activeSDK)
            encoder.append(path: facet)
        }
    }

    static let kind: ActionKind = "swift-sdk.publish-native-sysroot"

    let activeSDK: FilePath
    let facet: FilePath

    var identity: Identity {
        Identity(activeSDK: activeSDK, facet: facet)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(activeSDK)),
                ActionEffect(.write, scope: .publication(facet)),
            ], executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        guard try context.files.metadata(for: activeSDK)?.type == .directory else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "no active Swift SDK bundle at \(activeSDK) to face")
        }
        try context.files.replaceSymlink(at: facet, target: activeSDK.string)
    }
}

private struct SwiftSDKAssemblyTarget: Hashable, Sendable {
    let architecture: String
    let gnuArchitecture: String
    let triple: String
    let runtimeInstall: FilePath
    let packages: [FilePath]
}

package struct PublishSwiftSDKDiscoveryAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let path: FilePath
        let target: String
        let displacedItem: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: path)
            // The symbolic link's target is a path, and identity resolves paths
            // through the declared placement roots. Appending it as an ordinary
            // string kept the host's own directory in the identity, so the same
            // link published from a second checkout hashed differently.
            encoder.append(path: FilePath(target))
            encoder.append(path: displacedItem)
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
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .publication(path)),
                ActionEffect(.readWrite, scope: .publication(displacedItem)),
            ], executionPlatform: .macOSARM64Native)
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

private func linuxTripleSwiftSDKMetadata(
    triple: String,
    gnuArchitecture: String
) throws -> [UInt8] {
    let sdkRoot = NucleusLinuxABI.sdkDirectoryName
    var data = try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": "4.0",
            "targetTriples": [
                triple: [
                    "sdkRootPath": sdkRoot,
                    "librarySearchPaths": [
                        "\(sdkRoot)/usr/lib/swift/linux",
                        "\(sdkRoot)/usr/lib/\(gnuArchitecture)",
                    ],
                    "swiftResourcesPath": "\(sdkRoot)/usr/lib/swift",
                    "swiftStaticResourcesPath":
                        "\(sdkRoot)/usr/lib/swift_static",
                    "toolsetPaths": ["toolset.json"],
                ]
            ],
        ],
        options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    return Array(data)
}

private struct SanitizeLinuxSDKPackagesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let inputs: [FilePath]
        let outputRoot: FilePath
        let outputs: [FilePath]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.appendSequence(inputs) { $0.append(path: $1) }
            encoder.append(path: outputRoot)
            encoder.appendSequence(outputs) { $0.append(path: $1) }
        }
    }

    static let kind: ActionKind = "swift-sdk.sanitize-linux-packages"

    let inputs: [FilePath]
    let outputRoot: FilePath
    let outputs: [FilePath]
    let environment: [String: String]

    var identity: Identity {
        Identity(
            inputs: inputs,
            outputRoot: outputRoot,
            outputs: outputs)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: inputs.map { ActionEffect(.read, scope: .input($0)) }
                + [ActionEffect(.readWrite, scope: .output(outputRoot))],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        guard inputs.count == outputs.count else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "Linux SDK sanitizer input/output count differs")
        }
        if let output = outputs.first {
            try context.files.createDirectory(output.removingLastComponent())
        }
        for (input, output) in zip(inputs, outputs) {
            try sanitize(input, to: output, files: context.files)
        }
    }

    /// Rewrites a Debian package without the contents a compiler sysroot must
    /// not carry.
    ///
    /// Manual pages are never compiler inputs, and the eight netfilter
    /// target/match interfaces below exist in both cases, which collide on the
    /// case-insensitive filesystem macOS uses by default. Nucleus exposes none
    /// of them; the rest of the kernel UAPI stays intact.
    ///
    /// Done in process because the payload is `data.tar.zst` and macOS `tar`
    /// decompresses zstd by running an external `zstd` the task PATH does not
    /// carry. The `ar` container is written directly rather than shelled out
    /// to: its format is fixed, and writing it here lets every field that has
    /// no meaning for a build artifact be zero, so the same input produces the
    /// same bytes.
    private func sanitize(
        _ input: FilePath,
        to output: FilePath,
        files: ActionFileSystem
    ) throws {
        let staging = output.removingLastComponent()
            .appending(".sanitize-\(output.lastComponent?.string ?? "package")")
        try files.remove(staging)
        defer { try? files.remove(staging) }
        let unpacked = staging.appending("package")
        let root = staging.appending("root")
        try files.createDirectory(unpacked)
        try files.createDirectory(root)

        _ = try ArchiveReader(file: URL(fileURLWithPath: input.string))
            .extractContents(to: URL(fileURLWithPath: unpacked.string))
        let members = try files.listRecursively(unpacked).map(\.path)
        func member(_ prefix: String) throws -> FilePath {
            guard
                let found = members.first(where: {
                    $0.lastComponent?.string.hasPrefix(prefix) == true
                })
            else { throw SanitizeLinuxSDKPackageFailure.invalidPackage(input) }
            return found
        }
        let control = try member("control.tar")
        let data = try member("data.tar")
        let debianBinary = try member("debian-binary")

        _ = try ArchiveReader(file: URL(fileURLWithPath: data.string))
            .extractContents(to: URL(fileURLWithPath: root.string))
        for excluded in sanitizedSDKPackageExclusions {
            try files.remove(root.appending(excluded))
        }

        let rebuilt = staging.appending("data.tar.gz")
        let writer = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(
                format: .paxRestricted, filter: .gzip))
        try writer.open(file: URL(fileURLWithPath: rebuilt.string))
        try writer.archiveDirectory(URL(fileURLWithPath: root.string))
        try writer.finishEncoding()

        var container = Array("!<arch>\n".utf8)
        for (name, path) in [
            ("debian-binary", debianBinary),
            (control.lastComponent?.string ?? "control.tar", control),
            ("data.tar.gz", rebuilt),
        ] {
            let bytes = try files.read(path)
            container += arMemberHeader(name: name, size: bytes.count)
            container += bytes
            if bytes.count % 2 == 1 { container.append(0x0a) }
        }
        try files.remove(output)
        try files.write(container, to: output)
    }

    /// A fixed-width `ar` member header. Every field a build artifact has no
    /// use for is zero, so the same input produces the same archive.
    private func arMemberHeader(name: String, size: Int) -> [UInt8] {
        func padded(_ value: String, _ width: Int) -> String {
            value.count >= width
                ? String(value.prefix(width))
                : value + String(repeating: " ", count: width - value.count)
        }
        let header =
            padded(name, 16) + padded("0", 12) + padded("0", 6) + padded("0", 6)
            + padded("100644", 8) + padded(String(size), 10) + "`\n"
        return Array(header.utf8)
    }
}

/// Contents a compiler sysroot must not carry: manual pages, and the
/// case-colliding netfilter interfaces Nucleus does not expose.
private let sanitizedSDKPackageExclusions: [String] =
    [
        "usr/share/man"
    ]
    + [
        "CONNMARK", "connmark", "DSCP", "dscp", "MARK", "mark", "RATEEST", "rateest",
        "TCPMSS", "tcpmss",
    ].map { "usr/include/linux/netfilter/xt_\($0).h" }
    + [
        "ECN", "ecn", "TTL", "ttl",
    ].map { "usr/include/linux/netfilter_ipv4/ipt_\($0).h" }
    + [
        "HL", "hl",
    ].map { "usr/include/linux/netfilter_ipv6/ip6t_\($0).h" }

private enum SanitizeLinuxSDKPackageFailure: Error, CustomStringConvertible {
    case invalidPackage(FilePath)

    var description: String {
        switch self {
        case .invalidPackage(let path):
            "not a Debian package: \(path)"
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
        let pkgConfigDirectory: FilePath
        let targets: [SwiftSDKAssemblyTarget]
        let linuxManifest: [UInt8]
        let linuxMetadata: [UInt8]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: candidate)
            encoder.append(path: hostArchive)
            encoder.append(path: androidArchive)
            encoder.append(path: ndkRoot)
            encoder.append(path: generator)
            encoder.append(snapshot)
            encoder.append(linuxBundleID)
            encoder.append(androidBundleID)
            encoder.appendSequence(targets) { targetEncoder, target in
                targetEncoder.append(target.architecture)
                targetEncoder.append(target.gnuArchitecture)
                targetEncoder.append(target.triple)
                targetEncoder.append(path: target.runtimeInstall)
                targetEncoder.appendSequence(target.packages) { $0.append(path: $1) }
            }
            encoder.append(bytes: linuxManifest)
            encoder.append(bytes: linuxMetadata)
            encoder.append(path: pkgConfigDirectory)
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
    let pkgConfigDirectory: FilePath
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
            pkgConfigDirectory: pkgConfigDirectory,
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
                ActionEffect(.read, scope: .input(pkgConfigDirectory)),
                ActionEffect(.readWrite, scope: .output(candidate)),
            ]
                + targets.map {
                    ActionEffect(.read, scope: .input($0.runtimeInstall))
                }
                + packagePaths.map {
                    ActionEffect(.read, scope: .input($0))
                },
            executionPlatform: .macOSARM64Native)
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
        let expandedHostPayload = candidate.appending("host-payload")
        let hostToolchain = candidate.appending("toolchain")
        let generatedLinux = candidate.appending("generated-linux")
        let finalLinuxBundle = sdkRoot.appending(linuxBundle)
        let finalLinuxSDK = finalLinuxBundle.appending("swift-linux")

        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        try await run(
            executable: .path(FilePath("/usr/sbin/pkgutil")),
            arguments: ["--expand", hostArchive.string, expandedHost.string],
            workingDirectory: candidate,
            context: context)
        try context.files.createDirectory(expandedHostPayload)
        try await run(
            executable: .path(FilePath("/usr/bin/ditto")),
            arguments: ["--noacl", "-x", hostPayload.string, expandedHostPayload.string],
            workingDirectory: candidate,
            context: context)
        try context.files.createDirectory(hostToolchain)
        try await run(
            executable: .path(FilePath("/usr/bin/ditto")),
            arguments: [
                "--noacl",
                expandedHostPayload.appending("usr").string,
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
            // The generator names its output for the release it built from,
            // which is the release the builder image runs.
            let generatedTargetRoot = generatedTripleRoot.appending(
                "ubuntu-resolute.sdk")
            let finalTripleRoot = finalLinuxSDK.appending(target.triple)
            let finalTargetRoot = finalTripleRoot.appending(
                NucleusLinuxABI.sdkDirectoryName)
            try context.files.createDirectory(finalTripleRoot)
            var arguments = [
                "make-linux-sdk",
                "--no-host-toolchain",
                "--target", target.triple,
                "--distribution-name", "ubuntu",
                "--distribution-version", "26.04.1",
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
                    "--noacl",
                    generatedTargetRoot.string,
                    finalTargetRoot.string,
                ],
                workingDirectory: candidate,
                context: context)
            try await run(
                executable: .path(FilePath("/usr/bin/ditto")),
                arguments: [
                    "--noacl",
                    generatedTripleRoot.appending("toolset.json").string,
                    finalTripleRoot.appending("toolset.json").string,
                ],
                workingDirectory: candidate,
                context: context)
            try await run(
                executable: .path(FilePath("/usr/bin/ditto")),
                arguments: [
                    "--noacl",
                    target.runtimeInstall.appending("usr").string,
                    finalTargetRoot.appending("usr").string,
                ],
                workingDirectory: candidate,
                context: context)
            // These `.pc` files are the only staged content read from the
            // checkout, which carries an inheritable entry denying the builder
            // write and delete. Carried onto the copy, that entry leaves the
            // builder owning a file in its own store that it is denied
            // permission to remove, which strands the candidate and fails every
            // later assembly.
            //
            // `ditto --noacl` does not prevent it: the flag suppresses
            // inherited entries, while an entry already materialized on a
            // source file is copied regardless. `copy` is the primitive that
            // does, and it exists for this -- `COPYFILE_DATA | COPYFILE_STAT`
            // carries contents, mode, and timestamps without the source's
            // access-control list.
            let stagedPkgConfig = finalTargetRoot.appending("usr/share/pkgconfig")
            try context.files.createDirectory(stagedPkgConfig)
            for entry in try context.files.listDirectory(pkgConfigDirectory) {
                guard let name = entry.path.lastComponent else { continue }
                try context.files.copy(
                    from: entry.path,
                    to: stagedPkgConfig.appending(name.string))
            }
            try context.files.write(
                try linuxTripleSwiftSDKMetadata(
                    triple: target.triple,
                    gnuArchitecture: target.gnuArchitecture),
                to: finalTripleRoot.appending("swift-sdk.json"))
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "Swift SDK assembly failed")
        }
    }
}

private struct BuildSwiftSDKGeneratorAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let swift: FilePath
        let source: FilePath
        let scratch: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: swift)
            encoder.append(path: source)
            encoder.append(path: scratch)
            encoder.append("swift-sdk-generator")
            encoder.append("release")
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
            ],
            executionPlatform: .macOSARM64Native)
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "Swift SDK generator build failed")
        }
    }
}

private struct ValidateSwiftTargetSDKConsumerAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let hostSwift: FilePath
        let hostToolset: FilePath
        let hostToolsetBytes: [UInt8]
        let sdkRoot: FilePath
        let scratch: FilePath
        let fixture: FilePath
        let ndkRoot: FilePath
        let sdk: String
        let triple: String
        let executable: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: hostSwift)
            encoder.append(path: hostToolset)
            encoder.append(bytes: hostToolsetBytes)
            encoder.append(path: sdkRoot)
            encoder.append(path: scratch)
            encoder.append(path: fixture)
            encoder.append(path: ndkRoot)
            encoder.append(sdk)
            encoder.append(triple)
            encoder.append(path: executable)
        }
    }

    static let kind: ActionKind = "swift-sdk.validate-target-sdk-consumer"

    let hostSwift: FilePath
    let hostToolset: FilePath
    let hostToolsetBytes: [UInt8]
    let sdkRoot: FilePath
    let scratch: FilePath
    let fixture: FilePath
    let ndkRoot: FilePath
    let sdk: String
    let triple: String
    let executable: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            hostSwift: hostSwift,
            hostToolset: hostToolset,
            hostToolsetBytes: hostToolsetBytes,
            sdkRoot: sdkRoot,
            scratch: scratch,
            fixture: fixture,
            ndkRoot: ndkRoot,
            sdk: sdk,
            triple: triple,
            executable: executable)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "host-swift",
                    executable: .taskOutput(hostSwift),
                    role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .input(hostSwift)),
                ActionEffect(.read, scope: .input(sdkRoot)),
                ActionEffect(.read, scope: .checkout(fixture)),
                ActionEffect(.read, scope: .input(ndkRoot)),
                ActionEffect(.readWrite, scope: .output(scratch)),
                ActionEffect(
                    .readWrite,
                    scope: .output(executable.removingLastComponent())),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(scratch)
        try context.files.write(hostToolsetBytes, to: hostToolset)
        let buildArguments = [
            "--package-path", fixture.string,
            "--scratch-path", scratch.string,
            "--swift-sdks-path", sdkRoot.string,
            "--swift-sdk", sdk,
            "--triple", triple,
            "--toolset", hostToolset.string,
            "--build-system", "swiftbuild",
        ]
        try await run(
            executable: .taskOutput(hostSwift),
            arguments: ["build"] + buildArguments,
            workingDirectory: fixture,
            context: context)
        let binPath = try await queryBinPath(
            arguments: buildArguments,
            scratch: scratch,
            context: context)
        try context.files.createDirectory(executable.removingLastComponent())
        try context.files.copy(from: binPath.appending("hello"), to: executable)
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
        guard result.succeeded else {
            throw result.executionFailure(reason: "Swift SDK validation failed")
        }
    }

    private func queryBinPath(
        arguments: [String],
        scratch: FilePath,
        context: ActionContext
    ) async throws -> FilePath {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .taskOutput(hostSwift),
                arguments: ["build", "--show-bin-path"] + arguments,
                workingDirectory: fixture,
                environment: environment,
                output: .captured(limit: 64 * 1_024)))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Swift SDK validation failed")
        }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = FilePath(value).lexicallyNormalized()
        guard !value.isEmpty, path.isAbsolute, path.isContained(in: scratch)
        else {
            throw SwiftSDKValidationFailure.invalidBinPath(value)
        }
        return path
    }
}

private struct ValidateSwiftTargetSDKArtifactsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let linuxSDK: FilePath
        let validationRoot: FilePath
        let validator: FilePath
        let linuxSDKDirectoryName: String
        let minimumGlibcVersion: String
        let executablePaths: [FilePath]
        let marker: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: linuxSDK)
            encoder.append(path: validationRoot)
            encoder.append(path: validator)
            encoder.append(linuxSDKDirectoryName)
            encoder.append(minimumGlibcVersion)
            encoder.appendSequence(executablePaths) { $0.append(path: $1) }
            encoder.append(path: marker)
        }
    }

    static let kind: ActionKind = "swift-sdk.validate-target-sdk-artifacts"

    let linuxSDK: FilePath
    let validationRoot: FilePath
    let validator: FilePath
    let linuxSDKDirectoryName: String
    let minimumGlibcVersion: String
    let executablePaths: [FilePath]
    let marker: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            linuxSDK: linuxSDK,
            validationRoot: validationRoot,
            validator: validator,
            linuxSDKDirectoryName: linuxSDKDirectoryName,
            minimumGlibcVersion: minimumGlibcVersion,
            executablePaths: executablePaths,
            marker: marker)
    }

    var requirements: ActionRequirements {
        var effects = [
            ActionEffect(.read, scope: .input(linuxSDK)),
            ActionEffect(.read, scope: .input(validator)),
            ActionEffect(.write, scope: .output(marker)),
        ]
        effects += executablePaths.map {
            ActionEffect(.read, scope: .input($0))
        }
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "sdk-validator",
                    executable: .path(validator),
                    role: .operational)
            ],
            effects: effects,
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try validateCaseInsensitiveRepresentability()
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .path(validator),
                arguments: [
                    linuxSDK.string,
                    linuxSDKDirectoryName,
                    minimumGlibcVersion,
                ] + executablePaths.map(\.string),
                workingDirectory: validationRoot,
                environment: environment,
                output: .logged))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Swift SDK validation failed")
        }
        try context.files.write(Array("validated\n".utf8), to: marker)
    }

    private func validateCaseInsensitiveRepresentability() throws {
        let root = URL(fileURLWithPath: linuxSDK.string, isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in false })
        else {
            throw SwiftTargetSDKRecipeFailure.invalidInput(
                "cannot enumerate Linux Swift SDK at \(linuxSDK)")
        }
        var paths: [String: String] = [:]
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let folded = relative.lowercased()
            if let existing = paths[folded], existing != relative {
                throw SwiftTargetSDKRecipeFailure.invalidInput(
                    "Linux Swift SDK has case-distinct paths '\(existing)' and "
                        + "'\(relative)'")
            }
            paths[folded] = relative
        }
    }
}

private struct PrepareLinuxSysrootAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sysroot: FilePath
        let architecture: String
        let packages: [FilePath]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: sysroot)
            encoder.append(architecture)
            encoder.appendSequence(packages) { $0.append(path: $1) }
        }
    }

    static let kind: ActionKind = "swift-sdk.prepare-linux-sysroot"

    let sysroot: FilePath
    let architecture: String
    let packages: [FilePath]
    let environment: [String: String]

    var identity: Identity {
        Identity(
            sysroot: sysroot,
            architecture: architecture,
            packages: packages)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: packages.map {
                ActionEffect(.read, scope: .input($0))
            } + [
                ActionEffect(
                    .readWrite,
                    scope: .output(sysroot.removingLastComponent()))
            ],
            executionPlatform: .macOSARM64Native)
    }

    /// Unpacks the pinned Debian packages into the target sysroot.
    ///
    /// The payloads are `data.tar.zst`, and macOS `tar` decompresses zstd by
    /// running an external `zstd`, which the task PATH does not carry and
    /// should not: a deterministic transformation of already-pinned inputs has
    /// no reason to depend on what a host happens to have installed.
    /// `ContainerizationArchive` reads both the outer `ar` container and the
    /// compressed payload in process, so this behaves the same on any host and
    /// gains whatever compression that library supports.
    func execute(in context: ActionContext) async throws {
        let workingDirectory = sysroot.removingLastComponent()
        try context.files.createDirectory(workingDirectory)
        let staging = workingDirectory.appending(".sysroot-staging")
        try context.files.remove(staging)
        defer { try? context.files.remove(staging) }
        let root = staging.appending("root")
        try context.files.createDirectory(root)

        for package in packages {
            let unpacked = staging.appending("package")
            try context.files.remove(unpacked)
            try context.files.createDirectory(unpacked)
            _ = try ArchiveReader(file: URL(fileURLWithPath: package.string))
                .extractContents(to: URL(fileURLWithPath: unpacked.string))
            guard
                let payload = try context.files.listRecursively(unpacked).first(
                    where: {
                        $0.path.lastComponent?.string.hasPrefix("data.tar") == true
                    })
            else {
                throw PrepareLinuxSysrootFailure.missingPayload(package)
            }
            _ = try ArchiveReader(file: URL(fileURLWithPath: payload.path.string))
                .extractContents(to: URL(fileURLWithPath: root.string))
            try context.files.remove(unpacked)
        }

        // The packages assume the distribution's merged-/usr root links, which
        // no payload owns itself.
        for (link, target) in [("lib", "usr/lib"), ("lib64", "usr/lib64")] {
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(link).string,
                withDestinationPath: target)
        }

        for entry in try context.files.listRecursively(root) {
            guard let name = entry.path.lastComponent?.string else { continue }
            if name.hasPrefix("libstdc++") || name.hasPrefix("libstdcxx") {
                throw PrepareLinuxSysrootFailure.forbiddenLibraries(entry.path)
            }
        }
        for required in [
            root.appending("usr/include/c++/v1"),
            root.appending("usr/lib/\(architecture)/libc++.so.1"),
        ] where try context.files.metadataWithoutFollowingSymlinks(for: required) == nil {
            throw PrepareLinuxSysrootFailure.missingSysrootContents(required)
        }

        try context.files.remove(sysroot)
        try context.files.move(from: root, to: sysroot)
    }

}

private enum PrepareLinuxSysrootFailure: Error, CustomStringConvertible {
    case missingPayload(FilePath)
    case forbiddenLibraries(FilePath)
    case missingSysrootContents(FilePath)

    var description: String {
        switch self {
        case .missingPayload(let package):
            "Debian package carries no data payload: \(package)"
        case .forbiddenLibraries(let path):
            "Linux target sysroot contains forbidden libstdc++ files: \(path)"
        case .missingSysrootContents(let path):
            "Linux target sysroot is missing required contents: \(path)"
        }
    }
}

private enum SwiftSDKValidationFailure: Error {
    case invalidBinPath(String)
}
