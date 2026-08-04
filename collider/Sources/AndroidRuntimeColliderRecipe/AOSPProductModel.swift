import ColliderCore
import Foundation
import SystemPackage

struct AOSPProductSourceOverlay: Hashable, Sendable {
    let source: FilePath
    let relativeDestination: String
}

struct AOSPProductBuild: Hashable, Sendable {
    let productSource: FilePath
    let source: FilePath
    let repoLauncher: FilePath
    let sourceProvenance: FilePath
    let buildRoot: FilePath
    let ccacheDirectory: FilePath
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
