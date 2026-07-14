// The host state machine + 65 diagnostic codes + error codes. AndroidHostCore
// is the C++-interop-side host (it owns the renderer/runtime/Vulkan sub-states
// that require cxx-interop). The non-cxx NucleusAndroidJNI facade `AndroidHost`
// wraps an instance of this and is what swift-java extracts; this type carries
// the whole state machine.

public enum AndroidErrorCode: Int32 {
    case none = 0
    case invalid_handle = 1
    case allocation_failed = 2
    case registry_failed = 3
    case surface_null = 4
    case surface_acquire_failed = 5
    case no_surface = 6
    case not_started = 7
    case context_null = 8
    case asset_manager_failed = 9
    case asset_open_failed = 10
    case asset_read_failed = 11
    case asset_path_rejected = 12
    case runtime_not_attached = 13
    case render_not_started = 14
}

// Diagnostic code constants (1..65), matching Host.Diagnostic.
enum Diagnostic {
    static let platform_configured: Int32 = 1
    static let host_started: Int32 = 2
    static let window_attached: Int32 = 3
    static let window_focused: Int32 = 4
    static let surface_attached: Int32 = 5
    static let surface_width: Int32 = 6
    static let surface_height: Int32 = 7
    static let surface_format: Int32 = 8
    static let surface_generation: Int32 = 9
    static let host_frame_count: Int32 = 10
    static let host_last_frame_time_nanos: Int32 = 11
    static let view_width: Int32 = 12
    static let view_height: Int32 = 13
    static let density_milli: Int32 = 14
    static let configuration_generation: Int32 = 15
    static let touch_event_count: Int32 = 16
    static let last_touch_action: Int32 = 17
    static let last_touch_pointer_id: Int32 = 18
    static let last_touch_pointer_count: Int32 = 19
    static let last_touch_x_milli: Int32 = 20
    static let last_touch_y_milli: Int32 = 21
    static let last_touch_pressure_milli: Int32 = 22
    static let last_touch_time_nanos: Int32 = 23
    static let key_event_count: Int32 = 24
    static let last_key_action: Int32 = 25
    static let last_key_code: Int32 = 26
    static let last_key_repeat_count: Int32 = 27
    static let last_key_meta_state: Int32 = 28
    static let last_key_time_nanos: Int32 = 29
    static let ime_active: Int32 = 30
    static let queued_event_count: Int32 = 31
    static let dropped_event_count: Int32 = 32
    static let host_start_count: Int32 = 33
    static let host_stop_count: Int32 = 34
    static let window_attach_count: Int32 = 35
    static let window_detach_count: Int32 = 36
    static let window_focus_count: Int32 = 37
    static let surface_attach_count: Int32 = 38
    static let surface_change_count: Int32 = 39
    static let surface_detach_count: Int32 = 40
    static let ime_change_count: Int32 = 41
    static let asset_smoke_value: Int32 = 42
    static let asset_smoke_count: Int32 = 43
    static let runtime_attached: Int32 = 44
    static let runtime_started: Int32 = 45
    static let runtime_attach_count: Int32 = 46
    static let runtime_start_count: Int32 = 47
    static let runtime_frame_count: Int32 = 48
    static let runtime_drained_event_count: Int32 = 49
    static let runtime_stop_count: Int32 = 50
    static let runtime_detach_count: Int32 = 51
    static let runtime_last_frame_time_nanos: Int32 = 52
    static let runtime_last_event_hash: Int32 = 53
    static let render_attached: Int32 = 54
    static let render_started: Int32 = 55
    static let render_attempt_count: Int32 = 56
    static let render_post_count: Int32 = 57
    static let render_failure_count: Int32 = 58
    static let render_status_code: Int32 = 59
    static let render_last_buffer_width: Int32 = 60
    static let render_last_buffer_height: Int32 = 61
    static let render_last_buffer_stride: Int32 = 62
    static let render_last_buffer_format: Int32 = 63
    static let render_last_lock_result: Int32 = 64
    static let render_last_post_result: Int32 = 65
}

struct PlatformContext {
    var configured: Bool = false
    var asset_manager: UnsafeMutableRawPointer? = nil
    var density: Float = 1.0
    var sdk_int: Int32 = 0
    var files_dir: String? = nil
    var cache_dir: String? = nil
    var package_name: String? = nil

    // Always succeeds in Swift (String copies cannot fail allocation).
    mutating func configure(
        _ assetManager: UnsafeMutableRawPointer,
        _ density: Float,
        _ sdkInt: Int32,
        _ filesDir: String,
        _ cacheDir: String,
        _ packageName: String
    ) -> Bool {
        clear()
        self.asset_manager = assetManager
        self.density = density
        self.sdk_int = sdkInt
        self.files_dir = filesDir
        self.cache_dir = cacheDir
        self.package_name = packageName
        self.configured = true
        return true
    }

    mutating func clear() {
        files_dir = nil
        cache_dir = nil
        package_name = nil
        asset_manager = nil
        configured = false
        density = 1.0
        sdk_int = 0
    }
}

struct SurfaceState {
    var native_window: UnsafeMutableRawPointer? = nil
    var width: Int32 = 0
    var height: Int32 = 0
    var format: Int32 = 0
    var generation: UInt64 = 0

    mutating func attach(
        _ window: UnsafeMutableRawPointer,
        _ width: Int32,
        _ height: Int32,
        _ format: Int32
    ) -> UnsafeMutableRawPointer? {
        let previous = native_window
        native_window = window
        self.width = width
        self.height = height
        self.format = format
        generation &+= 1
        return previous
    }

    mutating func update(_ width: Int32, _ height: Int32, _ format: Int32) -> Bool {
        if native_window == nil { return false }
        self.width = width
        self.height = height
        self.format = format
        return true
    }

    mutating func detach() -> UnsafeMutableRawPointer? {
        guard let previous = native_window else { return nil }
        native_window = nil
        width = 0
        height = 0
        format = 0
        generation &+= 1
        return previous
    }

    mutating func take() -> UnsafeMutableRawPointer? {
        let previous = native_window
        native_window = nil
        width = 0
        height = 0
        format = 0
        generation &+= 1
        return previous
    }
}

struct FrameClock {
    var started: Bool = false
    var frame_count: UInt64 = 0
    var last_frame_time_nanos: Int64 = 0

    mutating func frame(_ frameTimeNanos: Int64) {
        frame_count &+= 1
        last_frame_time_nanos = frameTimeNanos
    }
}

struct TouchEvent {
    var action: Int32 = 0
    var pointer_id: Int32 = -1
    var pointer_count: Int32 = 0
    var x: Float = 0
    var y: Float = 0
    var pressure: Float = 0
    var event_time_nanos: Int64 = 0
}

struct KeyEvent {
    var action: Int32 = 0
    var key_code: Int32 = 0
    var repeat_count: Int32 = 0
    var meta_state: Int32 = 0
    var event_time_nanos: Int64 = 0
}

struct InputQueue {
    var attached_to_window: Bool = false
    var has_window_focus: Bool = false
    var view_width: Int32 = 0
    var view_height: Int32 = 0
    var density: Float = 1.0
    var configuration_generation: UInt64 = 0
    var touch_event_count: UInt64 = 0
    var key_event_count: UInt64 = 0
    var ime_active: Bool = false
    var last_touch: TouchEvent = TouchEvent()
    var last_key: KeyEvent = KeyEvent()

    mutating func configureView(_ width: Int32, _ height: Int32, _ density: Float) {
        view_width = width
        view_height = height
        self.density = density
        configuration_generation &+= 1
    }

    mutating func touch(_ event: TouchEvent) {
        last_touch = event
        touch_event_count &+= 1
    }

    mutating func key(_ event: KeyEvent) {
        last_key = event
        key_event_count &+= 1
    }
}

struct RuntimeSlot {
    var host: AndroidRuntimeHost = AndroidRuntimeHost()
    var asset_smoke_value: Int32 = 0
    var asset_smoke_count: UInt64 = 0
}

struct LifecycleStats {
    var start_count: UInt64 = 0
    var stop_count: UInt64 = 0
    var window_attach_count: UInt64 = 0
    var window_detach_count: UInt64 = 0
    var window_focus_count: UInt64 = 0
    var surface_attach_count: UInt64 = 0
    var surface_change_count: UInt64 = 0
    var surface_detach_count: UInt64 = 0
    var ime_change_count: UInt64 = 0
}

public final class AndroidHostCore {
    var platform = PlatformContext()
    var surface = SurfaceState()
    var frame_clock = FrameClock()
    var input = InputQueue()
    var events = AndroidEventQueue()
    var runtime = RuntimeSlot()
    var lifecycle = LifecycleStats()
    var last_error: AndroidErrorCode = .none

    public init() {}

    public func teardown() -> UnsafeMutableRawPointer? {
        platform.clear()
        return takeSurface()
    }

    public func start() -> Bool {
        frame_clock.started = true
        lifecycle.start_count &+= 1
        events.push(AndroidEvent(kind: .host_start))
        last_error = .none
        return true
    }

    public func stop() -> Bool {
        frame_clock.started = false
        lifecycle.stop_count &+= 1
        events.push(AndroidEvent(kind: .host_stop))
        last_error = .none
        return true
    }

    public func configureContext(
        _ assetManager: UnsafeMutableRawPointer,
        _ density: Float,
        _ sdkInt: Int32,
        _ filesDir: String,
        _ cacheDir: String,
        _ packageName: String
    ) -> Bool {
        if !platform.configure(assetManager, density, sdkInt, filesDir, cacheDir, packageName) {
            last_error = .allocation_failed
            return false
        }
        input.density = density
        last_error = .none
        return true
    }

    public func attachSurface(
        _ window: UnsafeMutableRawPointer,
        _ width: Int32,
        _ height: Int32,
        _ format: Int32
    ) -> UnsafeMutableRawPointer? {
        let previous = surface.attach(window, width, height, format)
        runtime.host.updateSurface(
            surface.native_window,
            surface.width,
            surface.height,
            surface.format,
            surface.generation
        )
        events.push(AndroidEvent(kind: .surface_attached, i0: width, i1: height, i2: format))
        lifecycle.surface_attach_count &+= 1
        last_error = .none
        return previous
    }

    public func updateSurface(_ width: Int32, _ height: Int32, _ format: Int32) -> Bool {
        if !surface.update(width, height, format) {
            last_error = .no_surface
            return false
        }
        runtime.host.updateSurface(
            surface.native_window,
            surface.width,
            surface.height,
            surface.format,
            surface.generation
        )
        events.push(AndroidEvent(kind: .surface_changed, i0: width, i1: height, i2: format))
        lifecycle.surface_change_count &+= 1
        last_error = .none
        return true
    }

    public func detachSurface() -> UnsafeMutableRawPointer? {
        guard let previous = surface.detach() else {
            last_error = .no_surface
            return nil
        }
        runtime.host.updateSurface(nil, 0, 0, 0, surface.generation)
        events.push(AndroidEvent(kind: .surface_detached))
        lifecycle.surface_detach_count &+= 1
        last_error = .none
        return previous
    }

    public func takeSurface() -> UnsafeMutableRawPointer? {
        return surface.take()
    }

    public func frame(_ frameTimeNanos: Int64) -> Bool {
        if !frame_clock.started {
            last_error = .not_started
            return false
        }
        if surface.native_window == nil {
            last_error = .no_surface
            return false
        }

        frame_clock.frame(frameTimeNanos)
        events.push(AndroidEvent(kind: .frame, time_nanos: frameTimeNanos))
        last_error = .none
        return true
    }

    public func windowAttached() -> Bool {
        input.attached_to_window = true
        lifecycle.window_attach_count &+= 1
        events.push(AndroidEvent(kind: .window_attached))
        last_error = .none
        return true
    }

    public func windowDetached() -> Bool {
        input.attached_to_window = false
        input.has_window_focus = false
        lifecycle.window_detach_count &+= 1
        events.push(AndroidEvent(kind: .window_detached))
        last_error = .none
        return true
    }

    public func windowFocusChanged(_ hasFocus: Bool) -> Bool {
        input.has_window_focus = hasFocus
        lifecycle.window_focus_count &+= 1
        events.push(AndroidEvent(kind: .window_focus, flag: hasFocus))
        last_error = .none
        return true
    }

    public func configurationChanged(_ width: Int32, _ height: Int32, _ density: Float) -> Bool {
        input.configureView(width, height, density)
        platform.density = density
        events.push(AndroidEvent(kind: .configuration, i0: width, i1: height, f0: density))
        last_error = .none
        return true
    }

    public func touchEvent(
        _ action: Int32,
        _ pointerId: Int32,
        _ pointerCount: Int32,
        _ x: Float,
        _ y: Float,
        _ pressure: Float,
        _ eventTimeNanos: Int64
    ) -> Bool {
        input.touch(TouchEvent(
            action: action,
            pointer_id: pointerId,
            pointer_count: pointerCount,
            x: x,
            y: y,
            pressure: pressure,
            event_time_nanos: eventTimeNanos
        ))
        events.push(AndroidEvent(
            kind: .touch,
            i0: action,
            i1: pointerId,
            i2: pointerCount,
            f0: x,
            f1: y,
            f2: pressure,
            time_nanos: eventTimeNanos
        ))
        last_error = .none
        return true
    }

    public func keyEvent(
        _ action: Int32,
        _ keyCode: Int32,
        _ repeatCount: Int32,
        _ metaState: Int32,
        _ eventTimeNanos: Int64
    ) -> Bool {
        input.key(KeyEvent(
            action: action,
            key_code: keyCode,
            repeat_count: repeatCount,
            meta_state: metaState,
            event_time_nanos: eventTimeNanos
        ))
        events.push(AndroidEvent(
            kind: .key,
            i0: action,
            i1: keyCode,
            i2: repeatCount,
            i3: metaState,
            time_nanos: eventTimeNanos
        ))
        last_error = .none
        return true
    }

    public func imeStateChanged(_ active: Bool) -> Bool {
        input.ime_active = active
        lifecycle.ime_change_count &+= 1
        events.push(AndroidEvent(kind: .ime, flag: active))
        last_error = .none
        return true
    }

    public func assetManager() -> UnsafeMutableRawPointer? {
        if !platform.configured {
            last_error = .context_null
            return nil
        }
        guard let manager = platform.asset_manager else {
            last_error = .asset_manager_failed
            return nil
        }
        last_error = .none
        return manager
    }

    @discardableResult
    public func recordAssetSmoke(_ value: Int32) -> Bool {
        runtime.asset_smoke_value = value
        runtime.asset_smoke_count &+= 1
        last_error = .none
        return true
    }

    public func drainEventQueueSmokeValue() -> Int32 {
        let value = events.drainSmokeValue()
        last_error = .none
        return value
    }

    public func runtimeAttach() -> Bool {
        let attached = runtime.host.attach(AttachSnapshot(
            platform_configured: platform.configured,
            asset_provider_available: platform.asset_manager != nil,
            surface_window: surface.native_window,
            surface_width: surface.width,
            surface_height: surface.height,
            surface_format: surface.format,
            surface_generation: surface.generation,
            density: platform.density,
            sdk_int: platform.sdk_int,
            queued_events: events.queuedCount()
        ))
        if !attached {
            last_error = .runtime_not_attached
            return false
        }
        events.push(AndroidEvent(kind: .runtime_attach))
        last_error = .none
        return true
    }

    public func runtimeStart() -> Bool {
        if !runtime.host.start() {
            last_error = .runtime_not_attached
            return false
        }
        events.push(AndroidEvent(kind: .runtime_start))
        last_error = .none
        return true
    }

    public func runtimeFrame(_ frameTimeNanos: Int64) -> Bool {
        let drainedEvents = events.drainStats()
        if !runtime.host.frame(frameTimeNanos, drainedEvents) {
            last_error = .render_not_started
            return false
        }
        events.push(AndroidEvent(kind: .runtime_frame, time_nanos: frameTimeNanos))
        last_error = .none
        return true
    }

    public func runtimeStop() -> Bool {
        if !runtime.host.stop() {
            last_error = .runtime_not_attached
            return false
        }
        events.push(AndroidEvent(kind: .runtime_stop))
        last_error = .none
        return true
    }

    public func runtimeDetach() -> Bool {
        if !runtime.host.detach() {
            last_error = .runtime_not_attached
            return false
        }
        events.push(AndroidEvent(kind: .runtime_detach))
        last_error = .none
        return true
    }

    public func runtimeSmokeValue() -> Int32 {
        last_error = .none
        return runtime.host.smokeValue()
    }

    public func runtimeVerificationValue() -> Int32 {
        last_error = .none
        return runtime.host.verificationValue()
    }

    public func renderSmokeValue() -> Int32 {
        last_error = .none
        return runtime.host.renderSmokeValue()
    }

    public func renderStatusCode() -> Int32 {
        last_error = .none
        return runtime.host.renderStatusCode()
    }

    public func diagnosticValue(_ code: Int32) -> Int64 {
        last_error = .none
        let renderer = runtime.host.renderer
        switch code {
        case Diagnostic.platform_configured: return boolValue(platform.configured)
        case Diagnostic.host_started: return boolValue(frame_clock.started)
        case Diagnostic.window_attached: return boolValue(input.attached_to_window)
        case Diagnostic.window_focused: return boolValue(input.has_window_focus)
        case Diagnostic.surface_attached: return boolValue(surface.native_window != nil)
        case Diagnostic.surface_width: return intValue(surface.width)
        case Diagnostic.surface_height: return intValue(surface.height)
        case Diagnostic.surface_format: return intValue(surface.format)
        case Diagnostic.surface_generation: return u64Value(surface.generation)
        case Diagnostic.host_frame_count: return u64Value(frame_clock.frame_count)
        case Diagnostic.host_last_frame_time_nanos: return frame_clock.last_frame_time_nanos
        case Diagnostic.view_width: return intValue(input.view_width)
        case Diagnostic.view_height: return intValue(input.view_height)
        case Diagnostic.density_milli: return intValue(scaleMilli(input.density))
        case Diagnostic.configuration_generation: return u64Value(input.configuration_generation)
        case Diagnostic.touch_event_count: return u64Value(input.touch_event_count)
        case Diagnostic.last_touch_action: return intValue(input.last_touch.action)
        case Diagnostic.last_touch_pointer_id: return intValue(input.last_touch.pointer_id)
        case Diagnostic.last_touch_pointer_count: return intValue(input.last_touch.pointer_count)
        case Diagnostic.last_touch_x_milli: return intValue(scaleMilli(input.last_touch.x))
        case Diagnostic.last_touch_y_milli: return intValue(scaleMilli(input.last_touch.y))
        case Diagnostic.last_touch_pressure_milli: return intValue(scaleMilli(input.last_touch.pressure))
        case Diagnostic.last_touch_time_nanos: return input.last_touch.event_time_nanos
        case Diagnostic.key_event_count: return u64Value(input.key_event_count)
        case Diagnostic.last_key_action: return intValue(input.last_key.action)
        case Diagnostic.last_key_code: return intValue(input.last_key.key_code)
        case Diagnostic.last_key_repeat_count: return intValue(input.last_key.repeat_count)
        case Diagnostic.last_key_meta_state: return intValue(input.last_key.meta_state)
        case Diagnostic.last_key_time_nanos: return input.last_key.event_time_nanos
        case Diagnostic.ime_active: return boolValue(input.ime_active)
        case Diagnostic.queued_event_count: return intValue(Int32(events.queuedCount()))
        case Diagnostic.dropped_event_count: return u64Value(events.droppedCount())
        case Diagnostic.host_start_count: return u64Value(lifecycle.start_count)
        case Diagnostic.host_stop_count: return u64Value(lifecycle.stop_count)
        case Diagnostic.window_attach_count: return u64Value(lifecycle.window_attach_count)
        case Diagnostic.window_detach_count: return u64Value(lifecycle.window_detach_count)
        case Diagnostic.window_focus_count: return u64Value(lifecycle.window_focus_count)
        case Diagnostic.surface_attach_count: return u64Value(lifecycle.surface_attach_count)
        case Diagnostic.surface_change_count: return u64Value(lifecycle.surface_change_count)
        case Diagnostic.surface_detach_count: return u64Value(lifecycle.surface_detach_count)
        case Diagnostic.ime_change_count: return u64Value(lifecycle.ime_change_count)
        case Diagnostic.asset_smoke_value: return intValue(runtime.asset_smoke_value)
        case Diagnostic.asset_smoke_count: return u64Value(runtime.asset_smoke_count)
        case Diagnostic.runtime_attached: return boolValue(runtime.host.attached)
        case Diagnostic.runtime_started: return boolValue(runtime.host.started)
        case Diagnostic.runtime_attach_count: return u64Value(runtime.host.attach_count)
        case Diagnostic.runtime_start_count: return u64Value(runtime.host.start_count)
        case Diagnostic.runtime_frame_count: return u64Value(runtime.host.frame_count)
        case Diagnostic.runtime_drained_event_count: return u64Value(runtime.host.drained_event_count)
        case Diagnostic.runtime_stop_count: return u64Value(runtime.host.stop_count)
        case Diagnostic.runtime_detach_count: return u64Value(runtime.host.detach_count)
        case Diagnostic.runtime_last_frame_time_nanos: return runtime.host.last_frame_time_nanos
        case Diagnostic.runtime_last_event_hash: return intValue(Int32(bitPattern: runtime.host.last_event_hash))
        case Diagnostic.render_attached: return boolValue(renderer.attached)
        case Diagnostic.render_started: return boolValue(renderer.started)
        case Diagnostic.render_attempt_count: return u64Value(renderer.render_attempt_count)
        case Diagnostic.render_post_count: return u64Value(renderer.render_post_count)
        case Diagnostic.render_failure_count: return u64Value(renderer.render_failure_count)
        case Diagnostic.render_status_code: return intValue(renderer.last_render_status.rawValue)
        case Diagnostic.render_last_buffer_width: return intValue(renderer.last_buffer_width)
        case Diagnostic.render_last_buffer_height: return intValue(renderer.last_buffer_height)
        case Diagnostic.render_last_buffer_stride: return intValue(renderer.last_buffer_stride)
        case Diagnostic.render_last_buffer_format: return intValue(renderer.last_buffer_format)
        case Diagnostic.render_last_lock_result: return intValue(renderer.last_lock_result)
        case Diagnostic.render_last_post_result: return intValue(renderer.last_post_result)
        default: return -1
        }
    }

    public func setError(_ code: AndroidErrorCode) {
        last_error = code
    }

    public func lastErrorCode() -> Int32 {
        return last_error.rawValue
    }

    // MARK: - Diagnostic value coercions

    private func boolValue(_ value: Bool) -> Int64 { value ? 1 : 0 }
    private func intValue(_ value: Int32) -> Int64 { Int64(value) }
    private func u64Value(_ value: UInt64) -> Int64 { Int64(bitPattern: value) }
    private func scaleMilli(_ value: Float) -> Int32 { Int32(value * 1000.0) }
}
