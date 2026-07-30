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
    public let sourceSuperprojectCommit: String
    public let sourceManifestSHA256: String
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
        sourceSuperprojectCommit: String,
        sourceManifestSHA256: String,
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
        self.sourceSuperprojectCommit = sourceSuperprojectCommit
        self.sourceManifestSHA256 = sourceManifestSHA256
        self.productTreeSHA256 = productTreeSHA256
        self.images = images
    }
}

public struct AndroidSourceProvenance: Decodable, Equatable, Sendable {
    public let status: String
    public let manifestCommit: String
    public let superprojectCommit: String
    public let resolvedManifestSHA256: String

    public init(
        status: String,
        manifestCommit: String,
        superprojectCommit: String,
        resolvedManifestSHA256: String
    ) {
        self.status = status
        self.manifestCommit = manifestCommit
        self.superprojectCommit = superprojectCommit
        self.resolvedManifestSHA256 = resolvedManifestSHA256
    }
}

public struct AndroidSourceLock: Decodable, Equatable, Sendable {
    public struct Source: Decodable, Equatable, Sendable {
        public let manifestCommit: String

        public init(manifestCommit: String) {
            self.manifestCommit = manifestCommit
        }
    }

    public let source: Source

    public init(source: Source) {
        self.source = source
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
        image.sourceSuperprojectCommit == source.superprojectCommit,
        image.sourceManifestSHA256 == source.resolvedManifestSHA256
    else {
        return "published images do not match the current AOSP source"
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
