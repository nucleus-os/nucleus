public struct AndroidForwardPatch: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct AndroidForwardPatchStack: Codable, Equatable, Sendable {
    public let repositoryPath: String
    public let baseCommit: String
    public let patchedCommit: String
    public let patchedTree: String
    public let patches: [AndroidForwardPatch]

    public init(
        repositoryPath: String,
        baseCommit: String,
        patchedCommit: String,
        patchedTree: String,
        patches: [AndroidForwardPatch]
    ) {
        self.repositoryPath = repositoryPath
        self.baseCommit = baseCommit
        self.patchedCommit = patchedCommit
        self.patchedTree = patchedTree
        self.patches = patches
    }
}

public struct AndroidImageProvenance: Decodable, Equatable, Sendable {
    public struct Image: Decodable, Equatable, Sendable {
        public let name: String
        public let size: UInt64
        public let storageFormat: String
        public let sha256: String

        public init(
            name: String,
            size: UInt64,
            storageFormat: String,
            sha256: String
        ) {
            self.name = name
            self.size = size
            self.storageFormat = storageFormat
            self.sha256 = sha256
        }
    }

    public let status: String
    public let product: String
    public let release: String
    public let variant: String
    public let buildNumber: String
    public let buildTimestamp: UInt64
    public let platformSDK: UInt32
    public let vendorAPILevel: UInt32
    public let sourceManifestCommit: String
    public let sourceBaseManifestSHA256: String
    public let sourceManifestSHA256: String
    public let sourceForwardPatches: [AndroidForwardPatchStack]
    public let productTreeSHA256: String
    public let images: [Image]

    public init(
        status: String,
        product: String,
        release: String,
        variant: String,
        buildNumber: String,
        buildTimestamp: UInt64,
        platformSDK: UInt32,
        vendorAPILevel: UInt32,
        sourceManifestCommit: String,
        sourceBaseManifestSHA256: String,
        sourceManifestSHA256: String,
        sourceForwardPatches: [AndroidForwardPatchStack],
        productTreeSHA256: String,
        images: [Image]
    ) {
        self.status = status
        self.product = product
        self.release = release
        self.variant = variant
        self.buildNumber = buildNumber
        self.buildTimestamp = buildTimestamp
        self.platformSDK = platformSDK
        self.vendorAPILevel = vendorAPILevel
        self.sourceManifestCommit = sourceManifestCommit
        self.sourceBaseManifestSHA256 = sourceBaseManifestSHA256
        self.sourceManifestSHA256 = sourceManifestSHA256
        self.sourceForwardPatches = sourceForwardPatches
        self.productTreeSHA256 = productTreeSHA256
        self.images = images
    }
}

public struct AndroidSourceProvenance: Decodable, Equatable, Sendable {
    public let status: String
    public let manifestCommit: String
    public let baseResolvedManifestSHA256: String
    public let resolvedManifestSHA256: String
    public let forwardPatches: [AndroidForwardPatchStack]

    public init(
        status: String,
        manifestCommit: String,
        baseResolvedManifestSHA256: String,
        resolvedManifestSHA256: String,
        forwardPatches: [AndroidForwardPatchStack]
    ) {
        self.status = status
        self.manifestCommit = manifestCommit
        self.baseResolvedManifestSHA256 = baseResolvedManifestSHA256
        self.resolvedManifestSHA256 = resolvedManifestSHA256
        self.forwardPatches = forwardPatches
    }
}

public struct AndroidPatchManifest: Decodable, Equatable, Sendable {
    public struct Repository: Decodable, Equatable, Sendable {
        public let path: String
        public let patches: [String]

        public init(path: String, patches: [String]) {
            self.path = path
            self.patches = patches
        }
    }

    public let repositories: [Repository]

    public init(repositories: [Repository]) {
        self.repositories = repositories
    }
}

public struct AndroidSourceLock: Decodable, Equatable, Sendable {
    public struct Platform: Decodable, Equatable, Sendable {
        public let manifestCommit: String

        public init(manifestCommit: String) {
            self.manifestCommit = manifestCommit
        }
    }

    public let platform: Platform

    public init(platform: Platform) {
        self.platform = platform
    }
}

public struct AndroidProductLock: Decodable, Equatable, Sendable {
    public let product: String
    public let release: String
    public let variant: String
    public let buildNumber: String
    public let buildTimestamp: UInt64
    public let platformSDK: UInt32
    public let vendorAPILevel: UInt32

    public init(
        product: String,
        release: String,
        variant: String,
        buildNumber: String,
        buildTimestamp: UInt64,
        platformSDK: UInt32,
        vendorAPILevel: UInt32
    ) {
        self.product = product
        self.release = release
        self.variant = variant
        self.buildNumber = buildNumber
        self.buildTimestamp = buildTimestamp
        self.platformSDK = platformSDK
        self.vendorAPILevel = vendorAPILevel
    }
}

public func androidImageStalenessReason(
    image: AndroidImageProvenance,
    source: AndroidSourceProvenance,
    patchManifest: AndroidPatchManifest,
    patchDigests: [String],
    sourceManifestCommit: String,
    productLock: AndroidProductLock,
    productTreeSHA256: String
) -> String? {
    guard source.status == "materialized" else {
        return "current AOSP source provenance is not materialized"
    }
    guard source.manifestCommit == sourceManifestCommit else {
        return "current AOSP source provenance does not match aosp.lock.json"
    }
    guard image.sourceManifestCommit == source.manifestCommit,
        image.sourceBaseManifestSHA256
            == source.baseResolvedManifestSHA256,
        image.sourceManifestSHA256 == source.resolvedManifestSHA256,
        image.sourceForwardPatches == source.forwardPatches
    else {
        return "published images do not match the current AOSP source"
    }
    guard patchManifest.repositories.count == source.forwardPatches.count
    else {
        return "current AOSP source provenance does not match patches.json"
    }
    var digestIndex = 0
    for (repository, stack) in zip(
        patchManifest.repositories,
        source.forwardPatches)
    {
        guard repository.path == stack.repositoryPath,
            repository.patches == stack.patches.map(\.path)
        else {
            return "current AOSP source provenance does not match patches.json"
        }
        for patch in stack.patches {
            guard digestIndex < patchDigests.count,
                patch.sha256 == patchDigests[digestIndex]
            else {
                return "current AOSP source provenance contains a stale patch digest"
            }
            digestIndex += 1
        }
    }
    guard digestIndex == patchDigests.count else {
        return "current AOSP patch digest inventory is inconsistent"
    }
    guard image.product == productLock.product,
        image.release == productLock.release,
        image.variant == productLock.variant,
        image.buildNumber == productLock.buildNumber,
        image.buildTimestamp == productLock.buildTimestamp,
        image.platformSDK == productLock.platformSDK,
        image.vendorAPILevel == productLock.vendorAPILevel
    else {
        return "published images do not match aosp-product.lock.json"
    }
    guard image.productTreeSHA256 == productTreeSHA256 else {
        return "published images do not match the current product definition"
    }
    return nil
}
