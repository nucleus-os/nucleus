public struct HostCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let retainedViews = HostCapabilities(rawValue: 1 << 0)
    public static let text = HostCapabilities(rawValue: 1 << 1)
    public static let images = HostCapabilities(rawValue: 1 << 2)
    public static let nativeInput = HostCapabilities(rawValue: 1 << 3)
    public static let environment = HostCapabilities(rawValue: 1 << 4)
    public static let accessibility = HostCapabilities(rawValue: 1 << 5)
    public static let platformSurfaces = HostCapabilities(rawValue: 1 << 6)
}

public enum FoundationHostProjection: String, CaseIterable, Sendable {
    case fabric
    case waylandShell
    case compositorOverlay
}

public struct HostCapabilityDeclaration: Sendable, Equatable {
    public var projection: FoundationHostProjection
    public var supported: HostCapabilities

    public init(
        projection: FoundationHostProjection,
        supported: HostCapabilities
    ) {
        self.projection = projection
        self.supported = supported
    }

    public func supports(_ capability: HostCapabilities) -> Bool {
        supported.contains(capability)
    }
}

public enum FoundationHostCapabilities {
    public static let declarations: [HostCapabilityDeclaration] = [
        HostCapabilityDeclaration(
            projection: .fabric,
            supported: [.retainedViews, .text, .images, .environment]),
        HostCapabilityDeclaration(
            projection: .waylandShell,
            supported: [
                .retainedViews, .text, .images, .nativeInput,
                .environment, .accessibility, .platformSurfaces,
            ]),
        HostCapabilityDeclaration(
            projection: .compositorOverlay,
            supported: [
                .retainedViews, .text, .images, .nativeInput,
                .environment, .accessibility, .platformSurfaces,
            ]),
    ]
}
