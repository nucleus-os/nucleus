import ColliderCore
import Foundation
import SystemPackage

enum AOSPCompileResult: TaskResultValue {}

func aospOutputWorkspace(apiLevel: UInt32) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "aosp-output",
            artifactTarget: .androidX86_64(apiLevel: apiLevel),
            role: "build"),
        capacityBytes: 300 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
}

func aospCompilerCacheWorkspace(
    apiLevel: UInt32
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "aosp-ccache",
            artifactTarget: .androidX86_64(apiLevel: apiLevel),
            role: "compiler-cache"),
        capacityBytes: 50 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
}

struct AOSPProductSourceOverlay: Hashable, Sendable {
    let source: FilePath
    let relativeDestination: String
}

struct AOSPProductBuild: Hashable, Sendable {
    let productSource: FilePath
    let source: FilePath
    let sourceProvenance: FilePath
    let artifactRoot: FilePath
    let outputWorkspace: PersistentWorkspaceDeclaration
    let compilerCacheWorkspace: PersistentWorkspaceDeclaration
    let containerImageID: FilePath
    let signingIdentity: FilePath
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let buildJobs: UInt32
    let expectedPlatformSDK: UInt32
    let expectedVendorAPILevel: UInt32
    let environment: [String: String]
    let sourceOverlays: [AOSPProductSourceOverlay]

    init(
        productSource: FilePath,
        source: FilePath,
        sourceProvenance: FilePath,
        artifactRoot: FilePath,
        outputWorkspace: PersistentWorkspaceDeclaration,
        compilerCacheWorkspace: PersistentWorkspaceDeclaration,
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
        self.sourceProvenance = sourceProvenance
        self.artifactRoot = artifactRoot
        self.outputWorkspace = outputWorkspace
        self.compilerCacheWorkspace = compilerCacheWorkspace
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

    var outputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/src/out",
            access: .readWrite)
    }

    var readOnlyOutputMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: outputWorkspace,
            target: "/src/out",
            access: .readOnly)
    }

    var compilerCacheMount: OCIPersistentWorkspaceMount {
        OCIPersistentWorkspaceMount(
            workspace: compilerCacheWorkspace,
            target: "/ccache",
            access: .readWrite)
    }

    var assembledProductSource: FilePath {
        artifactRoot.appending("product-input")
    }
}

func aospProductDefinitionDigest(
    productSource: FilePath,
    sourceOverlays: [AOSPProductSourceOverlay],
    files: ActionFileSystem
) throws -> ArtifactDigest {
    var bytes = try files.digest(tree: productSource).bytes
    for overlay in sourceOverlays.sorted(by: {
        $0.relativeDestination < $1.relativeDestination
    }) {
        bytes += Array(overlay.relativeDestination.utf8)
        bytes.append(0)
        bytes += try files.digest(tree: overlay.source).bytes
    }
    return ArtifactDigest.sha256(Data(bytes))
}
