// Runtime lifecycle + smoke/verification hashes.
//
// The renderer is owned by value, embedded as a struct field.

struct AttachSnapshot {
    var platform_configured: Bool = false
    var asset_provider_available: Bool = false
    var surface_window: UnsafeMutableRawPointer? = nil
    var surface_width: Int32 = 0
    var surface_height: Int32 = 0
    var surface_format: Int32 = 0
    var surface_generation: UInt64 = 0
    var density: Float = 1.0
    var sdk_int: Int32 = 0
    var queued_events: UInt32 = 0
}

struct AndroidRuntimeHost {
    var attached: Bool = false
    var started: Bool = false
    var attach_count: UInt64 = 0
    var start_count: UInt64 = 0
    var frame_count: UInt64 = 0
    var drained_event_count: UInt64 = 0
    var stop_count: UInt64 = 0
    var detach_count: UInt64 = 0
    var last_frame_time_nanos: Int64 = 0
    var last_event_hash: UInt32 = 2166136261
    var snapshot: AttachSnapshot = AttachSnapshot()
    var renderer: AndroidRenderer = AndroidRenderer()

    mutating func attach(_ snapshot: AttachSnapshot) -> Bool {
        if !snapshot.platform_configured { return false }
        self.snapshot = snapshot
        _ = renderer.attach(
            SurfaceBinding(
                window: snapshot.surface_window,
                width: snapshot.surface_width,
                height: snapshot.surface_height,
                format: snapshot.surface_format,
                generation: snapshot.surface_generation
            ),
            snapshot.asset_provider_available
        )
        attached = true
        started = false
        attach_count &+= 1
        return true
    }

    mutating func updateSurface(
        _ window: UnsafeMutableRawPointer?,
        _ width: Int32,
        _ height: Int32,
        _ format: Int32,
        _ generation: UInt64
    ) {
        if !attached { return }
        snapshot.surface_window = window
        snapshot.surface_width = width
        snapshot.surface_height = height
        snapshot.surface_format = format
        snapshot.surface_generation = generation
        renderer.updateSurface(
            SurfaceBinding(
                window: window,
                width: width,
                height: height,
                format: format,
                generation: generation
            )
        )
    }

    mutating func start() -> Bool {
        if !attached { return false }
        if !renderer.start() { return false }
        started = true
        start_count &+= 1
        return true
    }

    mutating func frame(_ frameTimeNanos: Int64, _ drainedEvents: DrainStats) -> Bool {
        if !started { return false }
        if !renderer.frame(frameTimeNanos, drainedEvents) { return false }
        last_frame_time_nanos = frameTimeNanos
        drained_event_count &+= UInt64(drainedEvents.count)
        last_event_hash = drainedEvents.hash
        frame_count &+= 1
        return true
    }

    mutating func stop() -> Bool {
        if !attached { return false }
        if !renderer.stop() { return false }
        started = false
        stop_count &+= 1
        return true
    }

    mutating func detach() -> Bool {
        if !attached { return false }
        _ = renderer.detach()
        started = false
        attached = false
        detach_count &+= 1
        return true
    }

    func smokeValue() -> Int32 {
        var hash: UInt32 = 2166136261
        hash = nucMix(hash, attached ? 1 : 0)
        hash = nucMix(hash, started ? 1 : 0)
        hash = nucMixU64(hash, attach_count)
        hash = nucMixU64(hash, start_count)
        hash = nucMixU64(hash, frame_count)
        hash = nucMixU64(hash, drained_event_count)
        hash = nucMixU64(hash, stop_count)
        hash = nucMixU64(hash, detach_count)
        hash = nucMixU64(hash, snapshot.surface_generation)
        hash = nucMix(hash, snapshot.queued_events)
        hash = nucMix(hash, last_event_hash)
        hash = nucMix(hash, UInt32(bitPattern: renderer.smokeValue()))
        return Int32(hash & 0x7fffffff)
    }

    func verificationValue() -> Int32 {
        var hash: UInt32 = 2166136261
        hash = nucMix(hash, snapshot.platform_configured ? 1 : 0)
        hash = nucMix(hash, snapshot.asset_provider_available ? 1 : 0)
        hash = nucMix(hash, renderer.surface_available_at_attach ? 1 : 0)
        hash = nucMixU64(hash, attach_count)
        hash = nucMixU64(hash, frame_count)
        hash = nucMixU64(hash, drained_event_count)
        hash = nucMix(hash, last_event_hash)
        hash = nucMix(hash, UInt32(bitPattern: renderer.smokeValue()))
        return Int32(hash & 0x7fffffff)
    }

    func renderSmokeValue() -> Int32 {
        return renderer.smokeValue()
    }

    func renderStatusCode() -> Int32 {
        return renderer.renderStatusCode()
    }
}
