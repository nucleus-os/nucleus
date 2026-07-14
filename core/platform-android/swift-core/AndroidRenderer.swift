// The Android renderer: lifecycle bookkeeping over the shared render stack. Each
// live-surface frame drives the `@MainActor` `AndroidRenderEngine` (the `RenderCore`
// + the `AndroidVulkanPresenter` swapchain backend) through `MainActor.assumeIsolated`:
// it records the retained NucleusUI scene into the acquired swapchain image (Skia
// Vulkan Graphite) and presents it through the single authoritative frame path.
// The engine is created lazily on the first frame with a live
// surface and torn down on detach; the swapchain is (re)created whenever the surface
// generation changes (resize / rotation / re-create). There is no CPU rendering path.

import NucleusAndroidC

enum RenderStatus: Int32 {
    case none = 0
    case posted = 1
    case no_surface = 2
    case invalid_surface = 3
    case recreated = 4
    case acquire_failed = 5
    case render_failed = 6
    case present_failed = 7
}

struct SurfaceBinding {
    var window: UnsafeMutableRawPointer? = nil
    var width: Int32 = 0
    var height: Int32 = 0
    var format: Int32 = 0
    var generation: UInt64 = 0
}

struct AndroidRenderer {
    var attached: Bool = false
    var started: Bool = false
    var surface_available_at_attach: Bool = false
    var asset_provider_available_at_attach: Bool = false
    var surface: SurfaceBinding = SurfaceBinding()
    var attach_count: UInt64 = 0
    var start_count: UInt64 = 0
    var frame_count: UInt64 = 0
    var stop_count: UInt64 = 0
    var detach_count: UInt64 = 0
    var last_frame_time_nanos: Int64 = 0
    var drained_event_count: UInt64 = 0
    var last_event_hash: UInt32 = 2166136261
    var render_attempt_count: UInt64 = 0
    var render_post_count: UInt64 = 0
    var render_failure_count: UInt64 = 0
    var last_render_status: RenderStatus = .none
    // Diagnostics, now sourced from the Vulkan presenter rather than the locked
    // ANativeWindow buffer (last_lock/post_result are vestigial — kept for the
    // stable diagnostic key set, always 0 on the Vulkan path).
    var last_lock_result: Int32 = 0
    var last_post_result: Int32 = 0
    var last_buffer_width: Int32 = 0
    var last_buffer_height: Int32 = 0
    var last_buffer_stride: Int32 = 0
    var last_buffer_format: Int32 = 0

    // The shared render stack (RenderCore + swapchain presenter), main-actor owned.
    // Reference type held by the value renderer; created on the first frame with a
    // live surface, torn down on detach.
    private var engine: AndroidRenderEngine? = nil
    private var engineSurfaceGeneration: UInt64? = nil

    @discardableResult
    mutating func attach(_ surface: SurfaceBinding, _ assetProviderAvailable: Bool) -> Bool {
        self.surface = surface
        self.surface_available_at_attach = surface.window != nil
        self.asset_provider_available_at_attach = assetProviderAvailable
        self.attached = true
        self.started = false
        self.attach_count &+= 1
        return true
    }

    mutating func updateSurface(_ surface: SurfaceBinding) {
        self.surface = surface
    }

    mutating func start() -> Bool {
        if !attached { return false }
        started = true
        start_count &+= 1
        return true
    }

    mutating func frame(_ frameTimeNanos: Int64, _ drainedEvents: DrainStats) -> Bool {
        if !started { return false }
        last_frame_time_nanos = frameTimeNanos
        drained_event_count &+= UInt64(drainedEvents.count)
        last_event_hash = drainedEvents.hash
        render_attempt_count &+= 1
        let status = renderVulkanFrame()
        last_render_status = status
        if status == .posted || status == .recreated {
            render_post_count &+= 1
        } else {
            render_failure_count &+= 1
        }
        frame_count &+= 1
        return true
    }

    mutating func stop() -> Bool {
        if !attached { return false }
        started = false
        stop_count &+= 1
        return true
    }

    @discardableResult
    mutating func detach() -> Bool {
        if !attached { return false }
        started = false
        attached = false
        surface = SurfaceBinding()
        last_render_status = .none
        if let engine { MainActor.assumeIsolated { engine.shutdown() } }
        engine = nil  // releases the render core + swapchain presenter
        engineSurfaceGeneration = nil
        detach_count &+= 1
        return true
    }

    func renderStatusCode() -> Int32 {
        return last_render_status.rawValue
    }

    func smokeValue() -> Int32 {
        var hash: UInt32 = 2166136261
        hash = nucMix(hash, attached ? 1 : 0)
        hash = nucMix(hash, started ? 1 : 0)
        hash = nucMix(hash, surface_available_at_attach ? 1 : 0)
        hash = nucMix(hash, asset_provider_available_at_attach ? 1 : 0)
        hash = nucMix(hash, UInt32(bitPattern: surface.width))
        hash = nucMix(hash, UInt32(bitPattern: surface.height))
        hash = nucMixU64(hash, surface.generation)
        hash = nucMixU64(hash, frame_count)
        hash = nucMixU64(hash, drained_event_count)
        hash = nucMix(hash, last_event_hash)
        hash = nucMixU64(hash, render_attempt_count)
        hash = nucMixU64(hash, render_post_count)
        hash = nucMixU64(hash, render_failure_count)
        hash = nucMix(hash, UInt32(bitPattern: last_render_status.rawValue))
        hash = nucMix(hash, UInt32(bitPattern: last_buffer_width))
        hash = nucMix(hash, UInt32(bitPattern: last_buffer_height))
        return Int32(hash & 0x7fffffff)
    }

    private mutating func renderVulkanFrame() -> RenderStatus {
        guard let window = surface.window else { return .no_surface }
        if surface.width <= 0 || surface.height <= 0 { return .invalid_surface }
        let width = surface.width, height = surface.height
        let generation = surface.generation, frameTime = last_frame_time_nanos
        // The ANativeWindow pointer is not Sendable; pass it as a bit pattern across
        // the main-actor closure boundary and reconstruct inside.
        let windowBits = UInt(bitPattern: window)

        // The render stack is main-actor isolated (the retained store + layers
        // commit sink are). Drive it through assumeIsolated, seeding a local so the
        // non-escaping closure does not capture `self` mutably.
        var localEngine = engine
        let previousGeneration = engineSurfaceGeneration
        let result: (status: RenderStatus, width: Int32, height: Int32) =
            MainActor.assumeIsolated {
                guard let window = UnsafeMutableRawPointer(bitPattern: windowBits) else {
                    return (.no_surface, 0, 0)
                }
                if previousGeneration != generation, let oldEngine = localEngine {
                    oldEngine.shutdown()
                    localEngine = nil
                }
                if localEngine == nil { localEngine = AndroidRenderEngine(window: window) }
                guard let engine = localEngine else { return (.invalid_surface, 0, 0) }
                let status = engine.frame(
                    width: width, height: height,
                    generation: generation, frameTimeNanos: frameTime)
                return (status, engine.lastExtentWidth, engine.lastExtentHeight)
            }
        engine = localEngine
        engineSurfaceGeneration = localEngine == nil ? nil : generation
        last_buffer_width = result.width
        last_buffer_height = result.height
        last_buffer_stride = result.width
        last_buffer_format = 0
        return result.status
    }
}
