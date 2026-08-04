import Foundation
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

public enum PathValidation: String, Hashable, Codable, Sendable {
    case exists
    case symlinkTarget
    case regularFile
    case executableFile
    case nonEmptyDirectory
    case json
}

public struct OutputDeclaration: Hashable, Sendable {
    public typealias Validation = PathValidation
    public let path: FilePath
    public let validation: PathValidation

    public init(path: FilePath, validation: PathValidation) {
        self.path = path
        self.validation = validation
    }
}

/// A path whose validity is required for task cleanliness but which is shared
/// state rather than an output owned by that task.
public struct PathPostcondition: Hashable, Sendable {
    public let path: FilePath
    public let validation: PathValidation

    public init(path: FilePath, validation: PathValidation) {
        self.path = path
        self.validation = validation
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

public struct CMakeDependencyRepair: Hashable, Sendable {
    public let configurationFileName: String
    public let package: String
    public let version: String
    public let configurationOnly: Bool

    public init(
        configurationFileName: String,
        package: String,
        version: String,
        configurationOnly: Bool = false
    ) {
        self.configurationFileName = configurationFileName
        self.package = package
        self.version = version
        self.configurationOnly = configurationOnly
    }
}

public struct LinkMetadataReplacement: Hashable, Sendable {
    public let fileName: String
    public let original: String
    public let replacement: String

    public init(
        fileName: String,
        original: String,
        replacement: String
    ) {
        self.fileName = fileName
        self.original = original
        self.replacement = replacement
    }
}

public struct LinkMetadataSanitization: Hashable, Sendable {
    public let root: FilePath
    public let removedLinkerOptions: [String]
    public let cmakeDependencyRepairs: [CMakeDependencyRepair]
    public let replacements: [LinkMetadataReplacement]

    public init(
        root: FilePath,
        removedLinkerOptions: [String],
        cmakeDependencyRepairs: [CMakeDependencyRepair] = [],
        replacements: [LinkMetadataReplacement] = []
    ) {
        self.root = root
        self.removedLinkerOptions = removedLinkerOptions
        self.cmakeDependencyRepairs = cmakeDependencyRepairs
        self.replacements = replacements
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
        case swiftBuildContext
        case swiftSDKCandidate
        case aospProduct
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

public struct AOSPPlatformSource: Hashable, Sendable {
    public let release: String
    public let revision: String
    public let manifestURL: String
    public let manifestRevision: String
    public let manifestCommit: String
    public let defaultManifestDigest: ArtifactDigest
    public let superprojectURL: String
    public let superprojectRevision: String
    public let superprojectCommit: String

    public init(
        release: String,
        revision: String,
        manifestURL: String,
        manifestRevision: String,
        manifestCommit: String,
        defaultManifestDigest: ArtifactDigest,
        superprojectURL: String,
        superprojectRevision: String,
        superprojectCommit: String
    ) {
        self.release = release
        self.revision = revision
        self.manifestURL = manifestURL
        self.manifestRevision = manifestRevision
        self.manifestCommit = manifestCommit
        self.defaultManifestDigest = defaultManifestDigest
        self.superprojectURL = superprojectURL
        self.superprojectRevision = superprojectRevision
        self.superprojectCommit = superprojectCommit
    }
}

public struct AOSPRepoSource: Hashable, Sendable {
    public let launcherVersion: String
    public let launcherDigest: ArtifactDigest
    public let repositoryURL: String
    public let revision: String
    public let tagObject: String
    public let commit: String

    public init(
        launcherVersion: String,
        launcherDigest: ArtifactDigest,
        repositoryURL: String,
        revision: String,
        tagObject: String,
        commit: String
    ) {
        self.launcherVersion = launcherVersion
        self.launcherDigest = launcherDigest
        self.repositoryURL = repositoryURL
        self.revision = revision
        self.tagObject = tagObject
        self.commit = commit
    }
}

public struct AOSPSourceSpecification: Hashable, Sendable {
    public let platform: AOSPPlatformSource
    public let repo: AOSPRepoSource

    public init(platform: AOSPPlatformSource, repo: AOSPRepoSource) {
        self.platform = platform
        self.repo = repo
    }
}

public struct AOSPSourceLockVerification: Hashable, Sendable {
    public let specification: AOSPSourceSpecification
    public let launcher: FilePath
    public let report: FilePath
    public let environment: [String: String]

    public init(
        specification: AOSPSourceSpecification,
        launcher: FilePath,
        report: FilePath,
        environment: [String: String]
    ) {
        self.specification = specification
        self.launcher = launcher
        self.report = report
        self.environment = environment
    }
}

public struct AOSPSourcePreparation: Hashable, Sendable {
    public let specification: AOSPSourceSpecification
    public let launcher: FilePath
    public let source: FilePath
    public let syncJobs: UInt32
    public let retryFetches: UInt32
    public let environment: [String: String]

    public init(
        specification: AOSPSourceSpecification,
        launcher: FilePath,
        source: FilePath,
        syncJobs: UInt32,
        retryFetches: UInt32,
        environment: [String: String]
    ) {
        self.specification = specification
        self.launcher = launcher
        self.source = source
        self.syncJobs = syncJobs
        self.retryFetches = retryFetches
        self.environment = environment
    }
}

public struct OCIImagePreparation: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let context: FilePath
    public let containerFile: FilePath
    public let imageID: FilePath
    public let imageName: String
    public let environment: [String: String]

    public init(
        executionPlatform: ExecutionPlatform,
        context: FilePath,
        containerFile: FilePath,
        imageID: FilePath,
        imageName: String,
        environment: [String: String]
    ) {
        self.executionPlatform = executionPlatform
        self.context = context
        self.containerFile = containerFile
        self.imageID = imageID
        self.imageName = imageName
        self.environment = environment
    }
}

public struct OCIMount: Hashable, Sendable {
    public enum Access: String, Hashable, Sendable {
        case readOnly
        case readWrite
    }

    public let source: FilePath
    public let target: String
    public let access: Access

    public init(source: FilePath, target: String, access: Access) {
        self.source = source
        self.target = target
        self.access = access
    }
}

public enum OCINetworkPolicy: String, Hashable, Sendable {
    case externalDisabled = "external-disabled"
    case externalEnabled = "external-enabled"
}

public struct OCIUserPolicy: Hashable, Sendable {
    public let userID: UInt32
    public let groupID: UInt32

    public init(userID: UInt32, groupID: UInt32) {
        self.userID = userID
        self.groupID = groupID
    }

    public static let builder = OCIUserPolicy(userID: 1000, groupID: 1000)
}

public enum OCICapabilityPolicy: String, Hashable, Sendable {
    case dropAll
}

public enum OCIPrivilegePolicy: String, Hashable, Sendable {
    case prohibitAcquisition
}

public enum OCIProcessFilesystemPolicy: String, Hashable, Sendable {
    case standard
    case unmasked
}

/// Controls whether the ARM Linux guest may execute Intel Linux binaries.
/// This is independent of the OCI image architecture: Nucleus always boots an
/// ARM64 Linux image on Apple silicon and enables translation only for tasks
/// that execute x86_64 artifacts.
public enum OCIIntelBinaryTranslationPolicy: String, Hashable, Sendable {
    case disabled
    case required
}

public struct OCIResourceLimits: Hashable, Sendable {
    public let cpuCount: UInt32?
    public let memoryBytes: UInt64?
    public let processCount: UInt32

    public init(
        cpuCount: UInt32?,
        memoryBytes: UInt64?,
        processCount: UInt32
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.processCount = processCount
    }

    public static let build = OCIResourceLimits(
        cpuCount: 20,
        memoryBytes: 96 * 1_024 * 1_024 * 1_024,
        processCount: 32_768)

    public static let parallelBuild = OCIResourceLimits(
        cpuCount: 11,
        memoryBytes: 56 * 1_024 * 1_024 * 1_024,
        processCount: 16_384)
}

public struct OCIExecution: Hashable, Sendable {
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget
    public let imageID: FilePath
    public let hostname: String
    public let workingDirectory: String
    public let hostWorkingDirectory: FilePath
    public let mounts: [OCIMount]
    public let temporaryDirectory: FilePath?
    public let networkPolicy: OCINetworkPolicy
    public let userPolicy: OCIUserPolicy
    public let capabilityPolicy: OCICapabilityPolicy
    public let privilegePolicy: OCIPrivilegePolicy
    public let processFilesystemPolicy: OCIProcessFilesystemPolicy
    public let intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy
    public let resourceLimits: OCIResourceLimits
    public let containerEnvironment: [String: String]
    public let command: [String]
    public let environment: [String: String]
    public let output: CommandSpec.Output

    public init(
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        imageID: FilePath,
        hostname: String,
        workingDirectory: String,
        hostWorkingDirectory: FilePath,
        mounts: [OCIMount],
        temporaryDirectory: FilePath? = nil,
        networkPolicy: OCINetworkPolicy,
        userPolicy: OCIUserPolicy,
        capabilityPolicy: OCICapabilityPolicy,
        privilegePolicy: OCIPrivilegePolicy,
        processFilesystemPolicy: OCIProcessFilesystemPolicy,
        intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy = .disabled,
        resourceLimits: OCIResourceLimits,
        containerEnvironment: [String: String],
        command: [String],
        environment: [String: String],
        output: CommandSpec.Output
    ) {
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
        self.imageID = imageID
        self.hostname = hostname
        self.workingDirectory = workingDirectory
        self.hostWorkingDirectory = hostWorkingDirectory
        self.mounts = mounts
        self.temporaryDirectory = temporaryDirectory
        self.networkPolicy = networkPolicy
        self.userPolicy = userPolicy
        self.capabilityPolicy = capabilityPolicy
        self.privilegePolicy = privilegePolicy
        self.processFilesystemPolicy = processFilesystemPolicy
        self.intelBinaryTranslationPolicy = intelBinaryTranslationPolicy
        self.resourceLimits = resourceLimits
        self.containerEnvironment = containerEnvironment
        self.command = command
        self.environment = environment
        self.output = output
    }
}

/// Shared configuration for the rootless native dependency builder.
public struct NativeOCIConfiguration: Sendable {
    public let context: FilePath
    public let imageID: FilePath
    public let ccache: FilePath
    public let swiftSDKRoot: FilePath
    public let environment: [String: String]

    public init(
        context: FilePath,
        imageID: FilePath,
        ccache: FilePath,
        swiftSDKRoot: FilePath,
        environment: [String: String]
    ) {
        self.context = context
        self.imageID = imageID
        self.ccache = ccache
        self.swiftSDKRoot = swiftSDKRoot
        self.environment = environment
    }
}

/// One Linux artifact lane produced inside the canonical ARM64 builder guest.
/// The execution architecture is deliberately not part of this value: every
/// lane executes in Linux/ARM64 and only the x86_64 lane enables Intel binary
/// translation when it runs target executables.
public struct NativeLinuxTarget: Hashable, Sendable {
    public let architecture: PlatformArchitecture

    public init(architecture: PlatformArchitecture) {
        precondition(architecture == .arm64 || architecture == .x86_64)
        self.architecture = architecture
    }

    public var identifier: String {
        "linux-\(architecture.rawValue)"
    }

    public var targetTriple: String {
        switch architecture {
        case .arm64: "aarch64-unknown-linux-gnu"
        case .x86_64: "x86_64-unknown-linux-gnu"
        }
    }

    public var gnuArchitecture: String {
        switch architecture {
        case .arm64: "aarch64-linux-gnu"
        case .x86_64: "x86_64-linux-gnu"
        }
    }

    public var artifactTarget: ArtifactTarget {
        switch architecture {
        case .arm64: .linuxARM64
        case .x86_64: .linuxX86_64
        }
    }

    public var intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy {
        architecture == .x86_64 ? .required : .disabled
    }

    public var skiaCPU: String {
        architecture == .arm64 ? "arm64" : "x64"
    }

    public var containerSwiftSDKRoot: String {
        "/swift-sdk/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
            + targetTriple + "/ubuntu-noble.sdk"
    }

    public var containerRuntimeLibraryPath: String {
        let root = containerSwiftSDKRoot
        return "\(root)/usr/lib/\(gnuArchitecture):\(root)/lib/\(gnuArchitecture)"
    }
}

public struct AOSPSigningIdentityPreparation: Hashable, Sendable {
    public let destination: FilePath
    public let subject: String
    public let environment: [String: String]

    public init(
        destination: FilePath,
        subject: String,
        environment: [String: String]
    ) {
        self.destination = destination
        self.subject = subject
        self.environment = environment
    }
}

public struct AOSPProductSourceOverlay: Hashable, Sendable {
    public let source: FilePath
    public let relativeDestination: String

    public init(source: FilePath, relativeDestination: String) {
        self.source = source
        self.relativeDestination = relativeDestination
    }
}

public struct AOSPProductBuild: Hashable, Sendable {
    public let productSource: FilePath
    public let source: FilePath
    public let repoLauncher: FilePath
    public let sourceProvenance: FilePath
    public let buildRoot: FilePath
    public let ccacheDirectory: FilePath
    public let containerImageID: FilePath
    public let signingIdentity: FilePath
    public let product: String
    public let release: String
    public let variant: String
    public let buildNumber: String
    public let buildTimestamp: UInt64
    public let buildJobs: UInt32
    public let expectedPlatformSDK: UInt32
    public let expectedVendorAPILevel: UInt32
    public let environment: [String: String]
    public let sourceOverlays: [AOSPProductSourceOverlay]

    public init(
        productSource: FilePath,
        source: FilePath,
        repoLauncher: FilePath,
        sourceProvenance: FilePath,
        buildRoot: FilePath,
        ccacheDirectory: FilePath,
        containerImageID: FilePath,
        signingIdentity: FilePath,
        product: String,
        release: String,
        variant: String,
        buildNumber: String,
        buildTimestamp: UInt64,
        buildJobs: UInt32,
        expectedPlatformSDK: UInt32,
        expectedVendorAPILevel: UInt32,
        environment: [String: String],
        sourceOverlays: [AOSPProductSourceOverlay] = []
    ) {
        self.productSource = productSource
        self.source = source
        self.repoLauncher = repoLauncher
        self.sourceProvenance = sourceProvenance
        self.buildRoot = buildRoot
        self.ccacheDirectory = ccacheDirectory
        self.containerImageID = containerImageID
        self.signingIdentity = signingIdentity
        self.product = product
        self.release = release
        self.variant = variant
        self.buildNumber = buildNumber
        self.buildTimestamp = buildTimestamp
        self.buildJobs = buildJobs
        self.expectedPlatformSDK = expectedPlatformSDK
        self.expectedVendorAPILevel = expectedVendorAPILevel
        self.environment = environment
        self.sourceOverlays = sourceOverlays
    }
}

public struct ChromiumSourceRepository: Codable, Hashable, Sendable {
    public let name: String
    public let checkoutPath: String
    public let remote: String
    public let upstreamRemote: String
    public let upstreamCommit: String
    public let commit: String
    public let tree: String

    public init(
        name: String,
        checkoutPath: String,
        remote: String,
        upstreamRemote: String,
        upstreamCommit: String,
        commit: String,
        tree: String
    ) {
        self.name = name
        self.checkoutPath = checkoutPath
        self.remote = remote
        self.upstreamRemote = upstreamRemote
        self.upstreamCommit = upstreamCommit
        self.commit = commit
        self.tree = tree
    }
}

public struct ChromiumDepotToolsLock: Codable, Hashable, Sendable {
    public let remote: String
    public let commit: String

    public init(remote: String, commit: String) {
        self.remote = remote
        self.commit = commit
    }
}

public struct ChromiumSourceLock: Codable, Hashable, Sendable {
    public let cefBranch: String
    public let chromiumVersion: String
    public let repositories: [ChromiumSourceRepository]
    public let depotTools: ChromiumDepotToolsLock

    public init(
        cefBranch: String,
        chromiumVersion: String,
        repositories: [ChromiumSourceRepository],
        depotTools: ChromiumDepotToolsLock
    ) {
        self.cefBranch = cefBranch
        self.chromiumVersion = chromiumVersion
        self.repositories = repositories
        self.depotTools = depotTools
    }
}

public struct ChromiumDepotToolsPreparation: Hashable, Sendable {
    public let repository: FilePath
    public let remote: String
    public let commit: String
    public let environment: [String: String]

    public init(
        repository: FilePath,
        remote: String,
        commit: String,
        environment: [String: String]
    ) {
        self.repository = repository
        self.remote = remote
        self.commit = commit
        self.environment = environment
    }
}

public struct ChromiumSourcePreparation: Hashable, Sendable {
    public let sourceID: String
    public let sourceRoot: FilePath
    public let sourceGenerations: FilePath
    public let current: FilePath
    public let depotTools: FilePath
    public let sourceLockFile: FilePath
    public let sourceLock: ChromiumSourceLock
    public let environment: [String: String]

    public init(
        sourceID: String,
        sourceRoot: FilePath,
        sourceGenerations: FilePath,
        current: FilePath,
        depotTools: FilePath,
        sourceLockFile: FilePath,
        sourceLock: ChromiumSourceLock,
        environment: [String: String]
    ) {
        self.sourceID = sourceID
        self.sourceRoot = sourceRoot
        self.sourceGenerations = sourceGenerations
        self.current = current
        self.depotTools = depotTools
        self.sourceLockFile = sourceLockFile
        self.sourceLock = sourceLock
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
    public let containerImageID: FilePath
    public let gnArguments: String?
    public let targets: [String]
    public let jobs: UInt32
    public let environment: [String: String]

    public init(
        product: ChromiumProduct,
        sourceRoot: FilePath,
        output: FilePath,
        depotTools: FilePath,
        containerImageID: FilePath,
        gnArguments: String? = nil,
        targets: [String],
        jobs: UInt32,
        environment: [String: String]
    ) {
        self.product = product
        self.sourceRoot = sourceRoot
        self.output = output
        self.depotTools = depotTools
        self.containerImageID = containerImageID
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
    public let chromiumSource: FilePath
    public let buildOutput: FilePath
    public let depotTools: FilePath
    public let distributionRoot: FilePath
    public let cefCheckout: String
    public let chromiumVersion: String
    public let environment: [String: String]

    public init(
        chromiumSource: FilePath,
        buildOutput: FilePath,
        depotTools: FilePath,
        distributionRoot: FilePath,
        cefCheckout: String,
        chromiumVersion: String,
        environment: [String: String]
    ) {
        self.chromiumSource = chromiumSource
        self.buildOutput = buildOutput
        self.depotTools = depotTools
        self.distributionRoot = distributionRoot
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

public struct ZipExtraction: Hashable, Sendable {
    public let archive: FilePath
    public let entry: String
    public let destination: FilePath
    public let environment: [String: String]

    public init(
        archive: FilePath,
        entry: String,
        destination: FilePath,
        environment: [String: String]
    ) {
        self.archive = archive
        self.entry = entry
        self.destination = destination
        self.environment = environment
    }
}

public struct FilePermissionUpdate: Hashable, Sendable {
    public let path: FilePath
    public let permissions: UInt16

    public init(path: FilePath, permissions: UInt16) {
        self.path = path
        self.permissions = permissions
    }
}

public enum AOSPProductOperationStage: String, Hashable, Sendable {
    case compile
    case sign
    case assembleImages = "assemble-images"
    case validate
    case publish
}

public enum TaskOperation: Hashable, Sendable {
    case action(AnyColliderAction)
    case command(CommandSpec)
    case runSwiftTest(SwiftTestExecution)
    case configureMeson(MesonSetup)
    case createDirectory(FilePath)
    case copyFile(source: FilePath, destination: FilePath)
    case copyMatchingFile(MatchingFileCopy)
    case extractZip(ZipExtraction)
    case removePath(FilePath)
    case replaceSymlink(path: FilePath, target: String)
    case setPermissions(FilePermissionUpdate)
    case writeFile(FilePath, bytes: [UInt8])
    case validateAndroidHost(AndroidHostValidation)
    case sanitizeLinkMetadata(LinkMetadataSanitization)
    case publishSymlink(SymlinkPublication)
    case publishDirectory(DirectoryPublication)
    case pruneDirectories(DirectoryRetentionPlan)
    case verifyAOSPSourceLock(AOSPSourceLockVerification)
    case prepareAOSPSource(AOSPSourcePreparation)
    case prepareOCIImage(OCIImagePreparation)
    case runOCI(OCIExecution)
    case prepareAOSPSigningIdentity(AOSPSigningIdentityPreparation)
    case aospProduct(AOSPProductOperationStage, AOSPProductBuild)
    case prepareChromiumDepotTools(ChromiumDepotToolsPreparation)
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

public struct SwiftTestExecution: Hashable, Sendable {
    public let invocation: SwiftPMInvocation
    public let package: String
    public let testProduct: String
    public let packageRoot: FilePath
    public let environment: [String: String]
    public let arguments: [String]

    public init(requirement: SwiftTestRequirement) {
        invocation = requirement.invocation
        package = requirement.package
        testProduct = requirement.testProduct
        packageRoot = requirement.packageRoot
        environment = requirement.environment
        arguments = requirement.arguments
    }
}

public enum TaskLock: Hashable, Sendable {
    case checkout(String)
    case shared(FilePath)
}

public enum TaskAssessmentPolicy: String, Hashable, Codable, Sendable {
    case always
    case incremental
    case portable
}

public struct TaskDeclaration: Hashable, Sendable {
    public let id: TaskID
    public let component: ComponentID
    public let dependencies: [TaskID]
    public let orderingDependencies: [TaskOrderingReference]
    public let artifactReferences: [AnyArtifactReference]
    public let resultReferences: [AnyTaskResultReference]
    public let outputSlots: [AnyTaskOutputSlot]
    public let resultSlots: [AnyTaskResultSlot]
    /// Direct dependency operations that this task's operation performs as a
    /// strict superset. Their identities still participate in this task's
    /// identity, but the runtime may omit their redundant operations when this
    /// task is dirty and selected.
    public let subsumedDependencies: [TaskID]
    public let swiftProducts: [SwiftProductRequirement]
    public let swiftTests: [SwiftTestRequirement]
    public let inputs: [ArtifactInput]
    public let outputs: [OutputDeclaration]
    public let postconditions: [PathPostcondition]
    public let locks: [TaskLock]
    public let assessmentPolicy: TaskAssessmentPolicy
    public let operation: TaskOperation

    public init(
        id: TaskID,
        component: ComponentID,
        dependencies: [TaskID] = [],
        orderingDependencies: [TaskOrderingReference] = [],
        artifactReferences: [AnyArtifactReference] = [],
        resultReferences: [AnyTaskResultReference] = [],
        outputSlots: [AnyTaskOutputSlot] = [],
        resultSlots: [AnyTaskResultSlot] = [],
        subsumedDependencies: [TaskID] = [],
        swiftProducts: [SwiftProductRequirement] = [],
        swiftTests: [SwiftTestRequirement] = [],
        inputs: [ArtifactInput] = [],
        outputs: [OutputDeclaration] = [],
        postconditions: [PathPostcondition] = [],
        locks: [TaskLock] = [],
        assessmentPolicy: TaskAssessmentPolicy = .incremental,
        operation: TaskOperation
    ) {
        self.id = id
        self.component = component
        self.dependencies = Self.uniqued(
            dependencies
                + artifactReferences.map(\.producer)
                + resultReferences.map(\.producer))
        self.orderingDependencies = orderingDependencies
        self.artifactReferences = artifactReferences
        self.resultReferences = resultReferences
        self.outputSlots = outputSlots
        self.resultSlots = resultSlots
        self.subsumedDependencies = subsumedDependencies
        self.swiftProducts = swiftProducts
        self.swiftTests = swiftTests
        self.inputs = inputs
        self.outputs = outputs
        self.postconditions = postconditions
        self.locks = locks
        self.assessmentPolicy = assessmentPolicy
        self.operation = operation
    }

    public var executionDependencies: [TaskID] {
        Self.uniqued(dependencies + orderingDependencies.map(\.producer))
    }

    private static func uniqued(_ values: [TaskID]) -> [TaskID] {
        var seen: Set<TaskID> = []
        return values.filter { seen.insert($0).inserted }
    }

    public func addingDependencies(
        _ additionalDependencies: [TaskID]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies
                + additionalDependencies.filter {
                    !dependencies.contains($0)
                },
            orderingDependencies: orderingDependencies,
            artifactReferences: artifactReferences,
            resultReferences: resultReferences,
            outputSlots: outputSlots,
            resultSlots: resultSlots,
            subsumedDependencies: subsumedDependencies,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputs,
            postconditions: postconditions,
            locks: locks,
            assessmentPolicy: assessmentPolicy,
            operation: operation)
    }

    public func addingLocks(_ additionalLocks: [TaskLock]) -> TaskDeclaration {
        TaskDeclaration(
            id: id,
            component: component,
            dependencies: dependencies,
            orderingDependencies: orderingDependencies,
            artifactReferences: artifactReferences,
            resultReferences: resultReferences,
            outputSlots: outputSlots,
            resultSlots: resultSlots,
            subsumedDependencies: subsumedDependencies,
            swiftProducts: swiftProducts,
            swiftTests: swiftTests,
            inputs: inputs,
            outputs: outputs,
            postconditions: postconditions,
            locks: locks + additionalLocks.filter { !locks.contains($0) },
            assessmentPolicy: assessmentPolicy,
            operation: operation)
    }
}

public enum TaskGraphFailure: Error, CustomStringConvertible, Sendable {
    case duplicate(TaskID)
    case missing(task: TaskID, dependency: TaskID)
    case invalidSubsumption(task: TaskID, dependency: TaskID)
    case unknownArtifactReference(
        task: TaskID, producer: TaskID, slot: OutputSlotID)
    case artifactReferenceMismatch(
        task: TaskID,
        producer: TaskID,
        slot: OutputSlotID,
        expected: ArtifactValueKind,
        actual: ArtifactValueKind)
    case unknownResultReference(
        task: TaskID, producer: TaskID, slot: OutputSlotID)
    case resultReferenceMismatch(
        task: TaskID,
        producer: TaskID,
        slot: OutputSlotID,
        expected: String,
        actual: String)
    case cycle([TaskID])

    public var description: String {
        switch self {
        case .duplicate(let id): "duplicate task identifier '\(id)'"
        case .missing(let task, let dependency):
            "task '\(task)' has missing dependency '\(dependency)'"
        case .invalidSubsumption(let task, let dependency):
            "task '\(task)' cannot subsume non-dependency '\(dependency)'"
        case .unknownArtifactReference(let task, let producer, let slot):
            "task '\(task)' references unknown artifact slot '\(producer).\(slot)'"
        case .artifactReferenceMismatch(
            let task, let producer, let slot, let expected, let actual):
            "task '\(task)' expects '\(expected.rawValue)' from "
                + "'\(producer).\(slot)', which produces '\(actual.rawValue)'"
        case .unknownResultReference(let task, let producer, let slot):
            "task '\(task)' references unknown result slot '\(producer).\(slot)'"
        case .resultReferenceMismatch(
            let task, let producer, let slot, let expected, let actual):
            "task '\(task)' expects result '\(expected)' from "
                + "'\(producer).\(slot)', which produces '\(actual)'"
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
            for dependency in declaration.executionDependencies
            where tasks[dependency] == nil {
                throw TaskGraphFailure.missing(task: declaration.id, dependency: dependency)
            }
            for dependency in declaration.subsumedDependencies
            where !declaration.dependencies.contains(dependency) {
                throw TaskGraphFailure.invalidSubsumption(
                    task: declaration.id,
                    dependency: dependency)
            }
            for reference in declaration.artifactReferences {
                guard
                    let producer = tasks[reference.producer],
                    let slot = producer.outputSlots.first(where: {
                        $0.id == reference.slot && $0.path == reference.path
                    })
                else {
                    throw TaskGraphFailure.unknownArtifactReference(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot)
                }
                guard slot.kind == reference.kind else {
                    throw TaskGraphFailure.artifactReferenceMismatch(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot,
                        expected: reference.kind,
                        actual: slot.kind)
                }
            }
            for reference in declaration.resultReferences {
                guard
                    let producer = tasks[reference.producer],
                    let slot = producer.resultSlots.first(where: {
                        $0.id == reference.slot
                    })
                else {
                    throw TaskGraphFailure.unknownResultReference(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot)
                }
                guard slot.valueType == reference.valueType else {
                    throw TaskGraphFailure.resultReferenceMismatch(
                        task: declaration.id,
                        producer: reference.producer,
                        slot: reference.slot,
                        expected: reference.valueType,
                        actual: slot.valueType)
                }
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
            for dependency in task.executionDependencies { try visit(dependency) }
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

    public init() {}

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
    return withUnsafeBytes(of: &bigEndian) { unsafe Array($0) }
}
