@MainActor
public final class AppearancePortal {
    public static let shared = AppearancePortal()

    private var colorScheme: UInt32 = 0
    private var contrast: UInt32 = 0
    private var epoch: UInt64 = 0

    private init() {}

    public func setColorScheme(_ value: UInt32) {
        let normalized = value == 1 || value == 2 ? value : 0
        guard colorScheme != normalized else { return }
        colorScheme = normalized
        epoch &+= 1
    }

    public func setContrast(_ value: UInt32) {
        let normalized = value == 1 ? UInt32(1) : UInt32(0)
        guard contrast != normalized else { return }
        contrast = normalized
        epoch &+= 1
    }

    public func snapshot() -> (UInt32, UInt32, UInt64) {
        (colorScheme, contrast, epoch)
    }
}
