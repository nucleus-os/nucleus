/// Swift-owned user settings and presentation animation for backdrop materials.
public struct BackdropDynamics: Sendable {
    public struct Material: Sendable, Equatable {
        public var enabled = true
        public var passes: UInt8 = 3
        public var offset: Float = 3
        public var noise: Float = 0.02
        public var saturation: Float = 1.5
        public var tint = SIMD4<Float>.zero
        public var alpha: Float = 1

        var isActive: Bool { enabled && offset > 0.0001 && alpha > 0.0001 }
    }

    public enum ControlMode: Sendable { case simple, advanced }
    public enum PresentationPolicy: Sendable { case immediate, animate, animateIfSignificant }

    public struct AdvancedControls: Sendable, Equatable {
        public var passes: UInt8?
        public var offset: Float?
        public var noise: Float?
        public var saturation: Float?
        public var tint: SIMD4<Float>?
        public var alpha: Float?
        public init() {}
    }

    public struct Settings: Sendable, Equatable {
        public var enabled = true
        public var intensity: Float = 0.8
        public var mode: ControlMode = .simple
        public var advanced = AdvancedControls()
        public var presentationOpacity: Float = 1
        public init() {}

        public var resolvedIntensity: Float { enabled ? min(max(intensity, 0), 1) : 0 }
    }

    private static let curve: [(Float, Float)] = [
        (0, 0), (0.2, 0.784), (0.4, 0.85), (0.6, 0.925), (0.8, 1), (1, 1.25),
    ]
    public static let shellOverlayTint = SIMD4<Float>(0.035, 0.085, 0.15, 0.42)

    public private(set) var target = Settings()
    public private(set) var presented = Settings()
    private var animationFrom = Settings()
    private var animationStartTime: Double?
    private var animationDuration: Float = 0

    public init() {}

    @discardableResult
    public mutating func setIntensity(_ intensity: Float, policy: PresentationPolicy = .animateIfSignificant) -> Bool {
        var settings = target
        settings.intensity = min(max(intensity, 0), 1)
        settings.enabled = settings.intensity > 0.0001
        return apply(settings, policy: policy)
    }

    @discardableResult
    public mutating func apply(_ settings: Settings, policy: PresentationPolicy) -> Bool {
        let targetChanged = target != settings
        let presentationChanged = !Self.materialsApproximatelyEqual(Self.resolveDefault(presented), Self.resolveDefault(settings))
        guard targetChanged || presentationChanged else { return false }
        target = settings
        let animate: Bool
        switch policy {
        case .immediate: animate = false
        case .animate: animate = presentationChanged
        case .animateIfSignificant:
            let current = Self.resolveDefault(presented)
            let next = Self.resolveDefault(settings)
            animate = current.isActive != next.isActive
                || abs(current.offset - next.offset) >= 0.1
                || abs(current.alpha - next.alpha) >= 0.05
                || abs(current.tint.w - next.tint.w) >= 0.02
        }
        if animate {
            animationFrom = presented
            animationStartTime = nil
            animationDuration = 0.22
        } else {
            presented = settings
            animationFrom = settings
            animationStartTime = nil
            animationDuration = 0
        }
        return true
    }

    public mutating func resolve(frameTime: Double) -> BackdropCatalog.Producers {
        tick(frameTime: frameTime)
        return .init(
            defaultMaterial: Self.resolveDefault(presented),
            waylandMaterial: Self.resolveDefault(presented),
            shellOverlayMaterial: Self.resolveShellOverlay()
        )
    }

    public var hasActiveAnimation: Bool {
        !Self.materialsApproximatelyEqual(Self.resolveDefault(presented), Self.resolveDefault(target))
    }

    private mutating func tick(frameTime: Double) {
        guard hasActiveAnimation else {
            presented = target
            animationStartTime = nil
            return
        }
        if animationStartTime == nil {
            animationFrom = presented
            animationStartTime = frameTime
            if animationDuration <= 0 { animationDuration = 0.22 }
        }
        let linear = Float(min(max((frameTime - animationStartTime!) / Double(max(animationDuration, 0.001)), 0), 1))
        let progress = linear * linear * (3 - 2 * linear)
        presented = Self.interpolate(animationFrom, target, progress)
        if linear >= 1 || !hasActiveAnimation {
            presented = target
            animationStartTime = nil
            animationDuration = 0
        }
    }

    public static func resolveDefault(_ settings: Settings) -> Material {
        let strength = strength(for: settings.resolvedIntensity)
        let finish = smoothstep((strength - 0.65) / 0.35)
        var material = Material(
            enabled: settings.enabled,
            passes: 3,
            offset: strength <= 0.0001 ? 0 : strength * 3,
            noise: 0.02 * finish,
            saturation: 1 + (1.5 - 1) * finish,
            tint: .zero,
            alpha: min(max(strength / 0.784, 0), 1) * min(max(settings.presentationOpacity, 0), 1)
        )
        if settings.mode == .advanced {
            if let value = settings.advanced.passes { material.passes = min(max(value, 1), 8) }
            if let value = settings.advanced.offset { material.offset = min(max(value, 0), 12) }
            if let value = settings.advanced.noise { material.noise = max(value, 0) }
            if let value = settings.advanced.saturation { material.saturation = max(value, 0) }
            if let value = settings.advanced.tint { material.tint = value }
            if let value = settings.advanced.alpha { material.alpha = min(max(value, 0), 1) }
        }
        material.enabled = settings.enabled && material.offset > 0.0001 && material.alpha > 0.0001
        if !material.enabled { material.offset = 0; material.alpha = 0 }
        return material
    }

    public static func resolveShellOverlay(opacity: Float = 1, tint: SIMD4<Float> = shellOverlayTint) -> Material {
        let alpha = min(max(opacity, 0), 1)
        return Material(enabled: alpha > 0.0001, passes: 3, offset: alpha > 0.0001 ? 3 : 0,
                        noise: 0.02, saturation: 1.5, tint: tint, alpha: alpha)
    }

    private static func strength(for intensity: Float) -> Float {
        let value = min(max(intensity, 0), 1)
        for index in 1..<curve.count where value <= curve[index].0 {
            let previous = curve[index - 1]
            let next = curve[index]
            let t = (value - previous.0) / (next.0 - previous.0)
            return previous.1 + (next.1 - previous.1) * t
        }
        return curve.last!.1
    }

    private static func smoothstep(_ value: Float) -> Float {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func interpolate(_ current: Settings, _ target: Settings, _ progress: Float) -> Settings {
        let t = min(max(progress, 0), 1)
        if t >= 0.9995 { return target }
        var next = target
        next.intensity = current.resolvedIntensity + (target.resolvedIntensity - current.resolvedIntensity) * t
        next.enabled = target.enabled || next.intensity > 0.0001
        let currentActive = resolveDefault(current).isActive
        let targetActive = resolveDefault(target).isActive
        let currentOpacity: Float = currentActive ? min(max(current.presentationOpacity, 0), 1) : 1
        let targetOpacity: Float = targetActive ? 1 : 0
        next.presentationOpacity = currentOpacity + (targetOpacity - currentOpacity) * t
        let currentMaterial = resolveDefault(current)
        next.advanced.offset = interpolate(current.advanced.offset, target.advanced.offset,
                                           fallback: currentMaterial.offset, progress: t)
        next.advanced.noise = interpolate(current.advanced.noise, target.advanced.noise,
                                          fallback: currentMaterial.noise, progress: t)
        next.advanced.saturation = interpolate(current.advanced.saturation, target.advanced.saturation,
                                               fallback: currentMaterial.saturation, progress: t)
        next.advanced.alpha = interpolate(current.advanced.alpha, target.advanced.alpha,
                                          fallback: currentMaterial.alpha, progress: t)
        if let targetTint = target.advanced.tint {
            let currentTint = current.advanced.tint ?? currentMaterial.tint
            next.advanced.tint = currentTint + (targetTint - currentTint) * t
        } else {
            next.advanced.tint = nil
        }
        return next
    }

    private static func interpolate(
        _ current: Float?, _ target: Float?, fallback: Float, progress: Float
    ) -> Float? {
        guard let target else { return nil }
        let start = current ?? fallback
        return start + (target - start) * progress
    }

    private static func materialsApproximatelyEqual(_ a: Material, _ b: Material) -> Bool {
        a.enabled == b.enabled && a.passes == b.passes
            && abs(a.offset - b.offset) <= 0.001
            && abs(a.noise - b.noise) <= 0.0001
            && abs(a.saturation - b.saturation) <= 0.001
            && abs(a.alpha - b.alpha) <= 0.001
            && abs(a.tint.x - b.tint.x) <= 0.001
            && abs(a.tint.y - b.tint.y) <= 0.001
            && abs(a.tint.z - b.tint.z) <= 0.001
            && abs(a.tint.w - b.tint.w) <= 0.001
    }
}
