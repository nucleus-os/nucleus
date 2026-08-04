public struct AndroidImageProvenance: Codable, Equatable, Sendable {
    public struct Image: Codable, Equatable, Sendable {
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
