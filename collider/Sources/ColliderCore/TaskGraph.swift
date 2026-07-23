import FoundationEssentials
import SystemPackage

public enum ArtifactInput: Hashable, Sendable {
    case value(name: String, bytes: [UInt8])
    case environment(name: String, value: String?)
    case file(FilePath)
    case tree(FilePath)
    /// Hashes a source tree when checked out and otherwise uses the repository
    /// gitlink identity so a fresh checkout can still plan its source-sync task.
    case optionalTree(FilePath, fallback: [UInt8])
    /// A path produced by an ordered dependency. Its producing dependency
    /// identity carries the content identity, so planning does not require the
    /// path to exist yet.
    case dependencyOutput(FilePath)
    case tool(CommandSpec.Executable)
}

public struct OutputDeclaration: Hashable, Sendable {
    public enum Validation: String, Hashable, Codable, Sendable {
        case exists
        case regularFile
        case executableFile
        case nonEmptyDirectory
        case json
    }

    public let path: FilePath
    public let validation: Validation

    public init(path: FilePath, validation: Validation) {
        self.path = path
        self.validation = validation
    }
}

public struct StaticArchiveMerge: Hashable, Sendable {
    public let sourceRoot: FilePath
    public let output: FilePath
    public let excludedFilePrefixes: [String]
    public let archiver: CommandSpec.Executable
    public let indexer: CommandSpec.Executable
    public let environment: [String: String]

    public init(
        sourceRoot: FilePath,
        output: FilePath,
        excludedFilePrefixes: [String] = [],
        archiver: CommandSpec.Executable = .named("ar"),
        indexer: CommandSpec.Executable = .named("ranlib"),
        environment: [String: String]
    ) {
        self.sourceRoot = sourceRoot
        self.output = output
        self.excludedFilePrefixes = excludedFilePrefixes
        self.archiver = archiver
        self.indexer = indexer
        self.environment = environment
    }
}

public struct MatchingFileCopy: Hashable, Sendable {
    public let searchDirectory: FilePath
    public let childDirectoryPrefix: String
    public let fileName: String
    public let destination: FilePath

    public init(
        searchDirectory: FilePath,
        childDirectoryPrefix: String,
        fileName: String,
        destination: FilePath
    ) {
        self.searchDirectory = searchDirectory
        self.childDirectoryPrefix = childDirectoryPrefix
        self.fileName = fileName
        self.destination = destination
    }
}

public struct GitPatchApplication: Hashable, Sendable {
    public let repository: FilePath
    public let patch: FilePath
    public let environment: [String: String]

    public init(
        repository: FilePath,
        patch: FilePath,
        environment: [String: String]
    ) {
        self.repository = repository
        self.patch = patch
        self.environment = environment
    }
}

public struct GitCheckoutValidation: Hashable, Sendable {
    public let repository: FilePath
    public let expectedCommit: String
    public let requireClean: Bool
    public let environment: [String: String]

    public init(
        repository: FilePath,
        expectedCommit: String,
        requireClean: Bool = true,
        environment: [String: String]
    ) {
        self.repository = repository
        self.expectedCommit = expectedCommit
        self.requireClean = requireClean
        self.environment = environment
    }
}

public struct GitCheckoutSync: Hashable, Sendable {
    public enum Revision: Hashable, Sendable {
        case branch(String)
        case tag(String)
        case commit(String)
    }

    public let repository: FilePath
    public let remote: String
    public let revision: Revision
    public let environment: [String: String]

    public init(
        repository: FilePath,
        remote: String,
        revision: Revision,
        environment: [String: String]
    ) {
        self.repository = repository
        self.remote = remote
        self.revision = revision
        self.environment = environment
    }
}

public struct MesonSetup: Hashable, Sendable {
    public let source: FilePath
    public let build: FilePath
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        source: FilePath,
        build: FilePath,
        arguments: [String],
        environment: [String: String]
    ) {
        self.source = source
        self.build = build
        self.arguments = arguments
        self.environment = environment
    }
}

public struct AndroidSDKWiring: Hashable, Sendable {
    public let bundle: FilePath
    public let ndk: FilePath
    public let minimumNDKMajorVersion: UInt32

    public init(
        bundle: FilePath,
        ndk: FilePath,
        minimumNDKMajorVersion: UInt32 = 27
    ) {
        self.bundle = bundle
        self.ndk = ndk
        self.minimumNDKMajorVersion = minimumNDKMajorVersion
    }
}

public struct AndroidSDKValidation: Hashable, Sendable {
    public let toolchain: FilePath
    public let sdkSearchRoot: FilePath
    public let bundleName: String
    public let ndk: FilePath
    public let architecture: String
    public let apiLevel: UInt32
    public let workDirectory: FilePath
    public let environment: [String: String]

    public init(
        toolchain: FilePath,
        sdkSearchRoot: FilePath,
        bundleName: String,
        ndk: FilePath,
        architecture: String,
        apiLevel: UInt32,
        workDirectory: FilePath,
        environment: [String: String]
    ) {
        self.toolchain = toolchain
        self.sdkSearchRoot = sdkSearchRoot
        self.bundleName = bundleName
        self.ndk = ndk
        self.architecture = architecture
        self.apiLevel = apiLevel
        self.workDirectory = workDirectory
        self.environment = environment
    }
}

public struct AndroidSDKAssembly: Hashable, Sendable {
    public let toolchain: FilePath
    public let installRoot: FilePath
    public let bundle: FilePath
    public let sourceID: String
    public let architectures: [String]
    public let apiLevel: UInt32

    public init(
        toolchain: FilePath,
        installRoot: FilePath,
        bundle: FilePath,
        sourceID: String,
        architectures: [String],
        apiLevel: UInt32
    ) {
        self.toolchain = toolchain
        self.installRoot = installRoot
        self.bundle = bundle
        self.sourceID = sourceID
        self.architectures = architectures
        self.apiLevel = apiLevel
    }
}

public struct AndroidRuntimeLinkageValidation: Hashable, Sendable {
    public let installRoot: FilePath
    public let ndk: FilePath
    public let architectures: [String]
    public let environment: [String: String]

    public init(
        installRoot: FilePath,
        ndk: FilePath,
        architectures: [String],
        environment: [String: String]
    ) {
        self.installRoot = installRoot
        self.ndk = ndk
        self.architectures = architectures
        self.environment = environment
    }
}

public struct AndroidHostValidation: Hashable, Sendable {
    public let library: FilePath
    public let kotlinContract: FilePath
    public let ndk: FilePath
    public let minimumSwiftJavaThunkCount: UInt32
    public let environment: [String: String]

    public init(
        library: FilePath,
        kotlinContract: FilePath,
        ndk: FilePath,
        minimumSwiftJavaThunkCount: UInt32 = 20,
        environment: [String: String]
    ) {
        self.library = library
        self.kotlinContract = kotlinContract
        self.ndk = ndk
        self.minimumSwiftJavaThunkCount = minimumSwiftJavaThunkCount
        self.environment = environment
    }
}

public enum HostToolchainPlatform: String, Hashable, Sendable {
    case linux
    case macOS
}

public struct HostToolchainBuildPreparation: Hashable, Sendable {
    public let workspace: FilePath
    public let stagingRoot: FilePath
    public let platform: HostToolchainPlatform

    public init(
        workspace: FilePath,
        stagingRoot: FilePath,
        platform: HostToolchainPlatform
    ) {
        self.workspace = workspace
        self.stagingRoot = stagingRoot
        self.platform = platform
    }
}

public struct HostToolchainAssembly: Hashable, Sendable {
    public let workspace: FilePath
    public let stagingRoot: FilePath
    public let toolchain: FilePath
    public let platform: HostToolchainPlatform

    public init(
        workspace: FilePath,
        stagingRoot: FilePath,
        toolchain: FilePath,
        platform: HostToolchainPlatform
    ) {
        self.workspace = workspace
        self.stagingRoot = stagingRoot
        self.toolchain = toolchain
        self.platform = platform
    }
}

public struct HostToolchainValidation: Hashable, Sendable {
    public let toolchain: FilePath
    public let platform: HostToolchainPlatform
    public let workDirectory: FilePath
    public let environment: [String: String]

    public init(
        toolchain: FilePath,
        platform: HostToolchainPlatform,
        workDirectory: FilePath,
        environment: [String: String]
    ) {
        self.toolchain = toolchain
        self.platform = platform
        self.workDirectory = workDirectory
        self.environment = environment
    }
}

public struct LinkMetadataSanitization: Hashable, Sendable {
    public let root: FilePath
    public let removedLinkerOptions: [String]

    public init(
        root: FilePath,
        removedLinkerOptions: [String]
    ) {
        self.root = root
        self.removedLinkerOptions = removedLinkerOptions
    }
}

public struct SymlinkPublication: Hashable, Sendable {
    public let path: FilePath
    public let target: String
    public let displacedItem: FilePath

    public init(
        path: FilePath,
        target: String,
        displacedItem: FilePath
    ) {
        self.path = path
        self.target = target
        self.displacedItem = displacedItem
    }
}

public struct DirectoryPublication: Hashable, Sendable {
    public let prepared: FilePath
    public let destination: FilePath

    public init(prepared: FilePath, destination: FilePath) {
        self.prepared = prepared
        self.destination = destination
    }
}

public struct DirectoryRetentionRule: Hashable, Sendable {
    public enum Naming: String, Hashable, Sendable {
        case contentIdentity
        case colliderRun
    }

    public let root: FilePath
    public let current: FilePath?
    public let retain: UInt32
    public let naming: Naming

    public init(
        root: FilePath,
        current: FilePath? = nil,
        retain: UInt32,
        naming: Naming
    ) {
        self.root = root
        self.current = current
        self.retain = retain
        self.naming = naming
    }
}

public struct DirectoryRetentionPlan: Hashable, Sendable {
    public let safetyRoot: FilePath
    public let rules: [DirectoryRetentionRule]

    public init(
        safetyRoot: FilePath,
        rules: [DirectoryRetentionRule]
    ) {
        self.safetyRoot = safetyRoot
        self.rules = rules
    }
}

public struct ChromiumPatchStack: Hashable, Sendable {
    public let repository: FilePath
    public let directory: FilePath

    public init(repository: FilePath, directory: FilePath) {
        self.repository = repository
        self.directory = directory
    }
}

public struct ChromiumSourcePreparation: Hashable, Sendable {
    public let workspace: FilePath
    public let sourceID: String
    public let sourceRoot: FilePath
    public let sourceGenerations: FilePath
    public let current: FilePath
    public let depotTools: FilePath
    public let automateScript: FilePath
    public let cefBranch: String
    public let cefCheckout: String
    public let chromiumCheckout: String
    public let depotToolsRevision: String
    public let patchStacks: [ChromiumPatchStack]
    public let environment: [String: String]

    public init(
        workspace: FilePath,
        sourceID: String,
        sourceRoot: FilePath,
        sourceGenerations: FilePath,
        current: FilePath,
        depotTools: FilePath,
        automateScript: FilePath,
        cefBranch: String,
        cefCheckout: String,
        chromiumCheckout: String,
        depotToolsRevision: String,
        patchStacks: [ChromiumPatchStack],
        environment: [String: String]
    ) {
        self.workspace = workspace
        self.sourceID = sourceID
        self.sourceRoot = sourceRoot
        self.sourceGenerations = sourceGenerations
        self.current = current
        self.depotTools = depotTools
        self.automateScript = automateScript
        self.cefBranch = cefBranch
        self.cefCheckout = cefCheckout
        self.chromiumCheckout = chromiumCheckout
        self.depotToolsRevision = depotToolsRevision
        self.patchStacks = patchStacks
        self.environment = environment
    }
}

public enum ChromiumProduct: String, Hashable, Sendable {
    case cef
    case browser
}

public struct ChromiumProductBuild: Hashable, Sendable {
    public let product: ChromiumProduct
    public let sourceRoot: FilePath
    public let output: FilePath
    public let depotTools: FilePath
    public let gnArguments: String?
    public let targets: [String]
    public let jobs: UInt32
    public let environment: [String: String]

    public init(
        product: ChromiumProduct,
        sourceRoot: FilePath,
        output: FilePath,
        depotTools: FilePath,
        gnArguments: String? = nil,
        targets: [String],
        jobs: UInt32,
        environment: [String: String]
    ) {
        self.product = product
        self.sourceRoot = sourceRoot
        self.output = output
        self.depotTools = depotTools
        self.gnArguments = gnArguments
        self.targets = targets
        self.jobs = jobs
        self.environment = environment
    }
}

public struct BrowserArtifactAssembly: Hashable, Sendable {
    public let chromiumSource: FilePath
    public let buildOutput: FilePath
    public let distributionRoot: FilePath
    public let launcher: FilePath
    public let desktopTemplate: FilePath
    public let environment: [String: String]

    public init(
        chromiumSource: FilePath,
        buildOutput: FilePath,
        distributionRoot: FilePath,
        launcher: FilePath,
        desktopTemplate: FilePath,
        environment: [String: String]
    ) {
        self.chromiumSource = chromiumSource
        self.buildOutput = buildOutput
        self.distributionRoot = distributionRoot
        self.launcher = launcher
        self.desktopTemplate = desktopTemplate
        self.environment = environment
    }
}

public struct CEFArtifactAssembly: Hashable, Sendable {
    public let sourceRoot: FilePath
    public let chromiumSource: FilePath
    public let buildOutput: FilePath
    public let depotTools: FilePath
    public let distributionRoot: FilePath
    public let cefBranch: String
    public let cefCheckout: String
    public let chromiumVersion: String
    public let environment: [String: String]

    public init(
        sourceRoot: FilePath,
        chromiumSource: FilePath,
        buildOutput: FilePath,
        depotTools: FilePath,
        distributionRoot: FilePath,
        cefBranch: String,
        cefCheckout: String,
        chromiumVersion: String,
        environment: [String: String]
    ) {
        self.sourceRoot = sourceRoot
        self.chromiumSource = chromiumSource
        self.buildOutput = buildOutput
        self.depotTools = depotTools
        self.distributionRoot = distributionRoot
        self.cefBranch = cefBranch
        self.cefCheckout = cefCheckout
        self.chromiumVersion = chromiumVersion
        self.environment = environment
    }
}

public struct BrowserInstallation: Hashable, Sendable {
    public let distributionRoot: FilePath
    public let prefix: FilePath
    public let systemSandboxDirectory: FilePath
    public let widevineCandidates: [FilePath]
    public let environment: [String: String]

    public init(
        distributionRoot: FilePath,
        prefix: FilePath,
        systemSandboxDirectory: FilePath = FilePath(
            "/usr/local/libexec/nucleus-browser"),
        widevineCandidates: [FilePath] = [
            FilePath("/opt/google/chrome/WidevineCdm"),
            FilePath("/opt/google/chrome-unstable/WidevineCdm"),
        ],
        environment: [String: String]
    ) {
        self.distributionRoot = distributionRoot
        self.prefix = prefix
        self.systemSandboxDirectory = systemSandboxDirectory
        self.widevineCandidates = widevineCandidates
        self.environment = environment
    }
}

public struct AptPackageValidation: Hashable, Sendable {
    public let packageList: FilePath
    public let environment: [String: String]

    public init(
        packageList: FilePath,
        environment: [String: String]
    ) {
        self.packageList = packageList
        self.environment = environment
    }
}

public enum TaskOperation: Hashable, Sendable {
    case applyGitPatch(GitPatchApplication)
    case command(CommandSpec)
    case configureMeson(MesonSetup)
    case createDirectory(FilePath)
    case copyFile(source: FilePath, destination: FilePath)
    case copyMatchingFile(MatchingFileCopy)
    case mergeStaticArchives(StaticArchiveMerge)
    case removePath(FilePath)
    case replaceSymlink(path: FilePath, target: String)
    case writeFile(FilePath, bytes: [UInt8])
    case syncGitCheckout(GitCheckoutSync)
    case validateGitCheckout(GitCheckoutValidation)
    case prepareHostToolchainBuild(HostToolchainBuildPreparation)
    case assembleHostToolchain(HostToolchainAssembly)
    case validateHostToolchain(HostToolchainValidation)
    case assembleAndroidSDK(AndroidSDKAssembly)
    case validateAndroidRuntimeLinkage(AndroidRuntimeLinkageValidation)
    case validateAndroidHost(AndroidHostValidation)
    case wireAndroidSDK(AndroidSDKWiring)
    case validateAndroidSDK(AndroidSDKValidation)
    case sanitizeLinkMetadata(LinkMetadataSanitization)
    case publishSymlink(SymlinkPublication)
    case publishDirectory(DirectoryPublication)
    case pruneDirectories(DirectoryRetentionPlan)
    case prepareChromiumSource(ChromiumSourcePreparation)
    case buildChromiumProduct(ChromiumProductBuild)
    case assembleBrowserArtifact(BrowserArtifactAssembly)
    case validateBrowserArtifact(BrowserArtifactAssembly)
    case assembleCEFArtifact(CEFArtifactAssembly)
    case validateCEFArtifact(CEFArtifactAssembly)
    case installBrowser(BrowserInstallation)
    case validateAptPackages(AptPackageValidation)
    case download(DownloadSpec, candidate: FilePath)
    case activateGeneration(candidate: FilePath, generation: FilePath, active: FilePath)
    indirect case sequence([TaskOperation])
}

public enum TaskLock: Hashable, Sendable {
    case checkout(String)
    case shared(FilePath)
}

public enum TaskCachePolicy: String, Hashable, Codable, Sendable {
    case contentAddressed
    case always
}

public struct TaskDeclaration: Hashable, Sendable {
    public let id: TaskID
    public let component: ComponentID
    public let schemaVersion: UInt32
    public let dependencies: [TaskID]
    public let inputs: [ArtifactInput]
    public let outputs: [OutputDeclaration]
    public let locks: [TaskLock]
    public let cachePolicy: TaskCachePolicy
    public let operation: TaskOperation

    public init(
        id: TaskID,
        component: ComponentID,
        schemaVersion: UInt32 = 1,
        dependencies: [TaskID] = [],
        inputs: [ArtifactInput] = [],
        outputs: [OutputDeclaration] = [],
        locks: [TaskLock] = [],
        cachePolicy: TaskCachePolicy = .contentAddressed,
        operation: TaskOperation
    ) {
        self.id = id
        self.component = component
        self.schemaVersion = schemaVersion
        self.dependencies = dependencies
        self.inputs = inputs
        self.outputs = outputs
        self.locks = locks
        self.cachePolicy = cachePolicy
        self.operation = operation
    }

    public func addingDependencies(
        _ additionalDependencies: [TaskID]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            schemaVersion: schemaVersion,
            dependencies: dependencies + additionalDependencies.filter {
                !dependencies.contains($0)
            },
            inputs: inputs,
            outputs: outputs,
            locks: locks,
            cachePolicy: cachePolicy,
            operation: operation)
    }
}

public enum TaskGraphFailure: Error, CustomStringConvertible, Sendable {
    case duplicate(TaskID)
    case missing(task: TaskID, dependency: TaskID)
    case cycle([TaskID])

    public var description: String {
        switch self {
        case .duplicate(let id): "duplicate task identifier '\(id)'"
        case .missing(let task, let dependency):
            "task '\(task)' has missing dependency '\(dependency)'"
        case .cycle(let path):
            "task dependency cycle: " + path.map(\.rawValue).joined(separator: " -> ")
        }
    }
}

public struct TaskGraph: Sendable {
    private let tasks: [TaskID: TaskDeclaration]

    public init(_ declarations: [TaskDeclaration]) throws {
        var tasks: [TaskID: TaskDeclaration] = [:]
        for declaration in declarations {
            guard tasks.updateValue(declaration, forKey: declaration.id) == nil else {
                throw TaskGraphFailure.duplicate(declaration.id)
            }
        }
        for declaration in declarations {
            for dependency in declaration.dependencies where tasks[dependency] == nil {
                throw TaskGraphFailure.missing(task: declaration.id, dependency: dependency)
            }
        }
        self.tasks = tasks
        _ = try orderedTasks(selecting: Array(tasks.keys))
    }

    public func orderedTasks(selecting selected: [TaskID]) throws -> [TaskDeclaration] {
        var permanent: Set<TaskID> = []
        var temporary: [TaskID] = []
        var result: [TaskDeclaration] = []

        func visit(_ id: TaskID) throws {
            if permanent.contains(id) { return }
            if let index = temporary.firstIndex(of: id) {
                throw TaskGraphFailure.cycle(Array(temporary[index...]) + [id])
            }
            guard let task = tasks[id] else {
                throw TaskGraphFailure.missing(task: id, dependency: id)
            }
            temporary.append(id)
            for dependency in task.dependencies { try visit(dependency) }
            temporary.removeLast()
            permanent.insert(id)
            result.append(task)
        }

        for id in selected { try visit(id) }
        return result
    }
}

public struct CanonicalDigestEncoder: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(schema: UInt32) {
        append(tag: 0, bytes: withBigEndianBytes(schema))
    }

    public mutating func append(tag: UInt8, string: String) {
        append(tag: tag, bytes: Array(string.utf8))
    }

    public mutating func append(tag: UInt8, bytes value: [UInt8]) {
        bytes.append(tag)
        bytes += withBigEndianBytes(UInt64(value.count))
        bytes += value
    }

    public mutating func append(tag: UInt8, integer: UInt64) {
        append(tag: tag, bytes: withBigEndianBytes(integer))
    }
}

private func withBigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Array($0) }
}
