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
public final class RuntimeEffect: Sendable {
    public let handle: UInt64
    private let resourceLifetime: LayerResourceLifetime?

    public init(
        handle: UInt64,
        resourceLifetime: LayerResourceLifetime? = nil,
        retain: Bool = true
    ) {
        self.handle = handle
        self.resourceLifetime = resourceLifetime
        if retain && handle != 0 {
            resourceLifetime?.lifecycle.runtimeEffectLifecycle.retain(handle: handle)
        }
    }

    deinit {
        if handle != 0 {
            resourceLifetime?.lifecycle.runtimeEffectLifecycle.release(handle: handle)
        }
    }

    /// Register an SkSL program, or share the handle of an identical one
    /// already registered.
    @MainActor
    public static func register(
        sksl: String, in context: Context
    ) throws(LayerError) -> RuntimeEffect {
        let registrar = context.runtimeHost.operations.runtimeEffectRegistrar
        do {
            let handle = try registrar.register(sksl: sksl)
            return RuntimeEffect(
                handle: handle,
                resourceLifetime: context.runtimeHost.resourceLifetime,
                retain: false)
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
