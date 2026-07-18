import NucleusAppHostProtocols

/// A registered SkSL program, referenced by paint commands through
/// `PaintCommand.effectHandle`. Refcounted like `PaintContent`: registered at 1,
/// released on `deinit`, evicted at 0.
///
/// Registration carries only the source; the renderer compiles at rasterization
/// time and caches the compiled program per handle. Uniforms are *not* part of
/// the registration — they ride the per-frame payload blob, because they change
/// every frame while the program does not. That split is the reason this store
/// exists rather than compiling at each draw.
public final class RuntimeEffect: @unchecked Sendable {
    public let handle: UInt64

    public init(handle: UInt64, retain: Bool = true) {
        self.handle = handle
        if retain && handle != 0 {
            currentLifecycleHost()?.runtimeEffectLifecycle.retain(handle: handle)
        }
    }

    deinit {
        if handle != 0 {
            currentLifecycleHost()?.runtimeEffectLifecycle.release(handle: handle)
        }
    }

    /// Register an SkSL program, or share the handle of an identical one
    /// already registered.
    @MainActor
    public static func register(sksl: String) throws(LayerError) -> RuntimeEffect {
        guard let registrar = currentHost()?.runtimeEffectRegistrar else {
            throw LayerError.backendFailure(detail: "register runtime effect: layers host not installed")
        }
        do {
            let handle = try registrar.register(sksl: sksl)
            return RuntimeEffect(handle: handle, retain: false)
        } catch let err {
            switch err {
            case .invalidHandle:
                throw LayerError.invalidHandle(detail: "register runtime effect: invalid handle")
            case .invalidArgument:
                throw LayerError.invalidArgument(detail: "register runtime effect: empty source")
            case .outOfMemory:
                throw LayerError.outOfMemory
            }
        }
    }
}
