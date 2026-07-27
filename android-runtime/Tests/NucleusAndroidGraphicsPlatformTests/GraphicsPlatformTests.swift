import Glibc
import Testing
import NucleusAndroidDrmC
import NucleusAndroidDrmCTestSupport
import NucleusAndroidGraphicsContract
@testable import NucleusAndroidGraphicsPlatform

private struct RawGraphicsTestError: Error, CustomStringConvertible {
    let description: String
}

@safe private final class RawGraphicsTestGPU: @unchecked Sendable {
    let handle: OpaquePointer
    let format = nucleus_android_drm_format_xrgb8888()
    let modifier: UInt64

    init(candidate: DrmDeviceCandidate) throws {
        let rawFormat = nucleus_android_drm_format_xrgb8888()
        var error = [CChar](repeating: 0, count: 1_024)
        guard let handle = candidate.renderNode.withCString({ path in
            unsafe nucleus_android_gpu_create(path, &error, error.count)
        }) else {
            throw RawGraphicsTestError(description: Self.errorString(error))
        }

        let modifierCount = unsafe nucleus_android_gpu_list_format_modifiers(
            handle,
            rawFormat,
            nil,
            0)
        guard modifierCount > 0 else {
            unsafe nucleus_android_gpu_destroy(handle)
            throw RawGraphicsTestError(description: "GPU exposes no XRGB8888 modifiers")
        }
        var modifiers = [nucleus_android_format_modifier_properties](
            repeating: .init(),
            count: Int(modifierCount))
        let returnedCount = modifiers.withUnsafeMutableBufferPointer { storage in
            unsafe nucleus_android_gpu_list_format_modifiers(
                handle,
                rawFormat,
                storage.baseAddress,
                storage.count)
        }
        let selected = modifiers.prefix(max(0, min(Int(returnedCount), modifiers.count)))
            .first {
                unsafe nucleus_android_gpu_supports_format_modifier(
                    handle,
                    rawFormat,
                    $0.modifier) == 1
            }
        guard let selected else {
            unsafe nucleus_android_gpu_destroy(handle)
            throw RawGraphicsTestError(
                description: "GPU exposes no renderable XRGB8888 modifier")
        }

        unsafe self.handle = handle
        modifier = selected.modifier
    }

    deinit {
        unsafe nucleus_android_gpu_destroy(handle)
    }

    func diagnostic() throws -> nucleus_android_gpu_diagnostic {
        var diagnostic = nucleus_android_gpu_diagnostic()
        guard unsafe nucleus_android_gpu_get_diagnostic(
            handle,
            &diagnostic) == 0
        else {
            throw RawGraphicsTestError(description: "GPU diagnostic unavailable")
        }
        return diagnostic
    }

    func collect() throws {
        guard unsafe nucleus_android_gpu_collect(handle) == 0 else {
            throw RawGraphicsTestError(description: "GPU collection failed")
        }
    }

    func forceFencesPending(_ enabled: Bool) {
        unsafe nucleus_android_test_gpu_force_fences_pending(
            handle,
            enabled ? 1 : 0)
    }

    func failNextPostSubmitStep() {
        unsafe nucleus_android_test_gpu_fail_next_post_submit(handle)
    }

    private static func errorString(_ error: [CChar]) -> String {
        error.withUnsafeBufferPointer { storage in
            unsafe String(cString: storage.baseAddress!)
        }
    }
}

@safe private final class RawGraphicsTestTimeline: @unchecked Sendable {
    let gpu: RawGraphicsTestGPU
    let handle: OpaquePointer

    init(gpu: RawGraphicsTestGPU) throws {
        guard let handle = unsafe nucleus_android_syncobj_timeline_create(
            gpu.handle)
        else {
            throw RawGraphicsTestError(description: "syncobj timeline creation failed")
        }
        self.gpu = gpu
        unsafe self.handle = handle
    }

    deinit {
        unsafe nucleus_android_syncobj_timeline_destroy(handle)
    }

    func signal(_ point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_timeline_signal(handle, point) == 0
    }

    func isSignaled(_ point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_timeline_is_signaled(handle, point) == 1
    }
}

@safe private final class RawGraphicsTestBuffer: @unchecked Sendable {
    let gpu: RawGraphicsTestGPU
    private var handle: OpaquePointer?

    init(gpu: RawGraphicsTestGPU) throws {
        var error = [CChar](repeating: 0, count: 1_024)
        guard let handle = unsafe nucleus_android_gpu_buffer_create(
            gpu.handle,
            64,
            64,
            gpu.format,
            gpu.modifier,
            0,
            &error,
            error.count)
        else {
            throw RawGraphicsTestError(
                description: error.withUnsafeBufferPointer {
                    unsafe String(cString: $0.baseAddress!)
                })
        }
        self.gpu = gpu
        unsafe self.handle = handle
    }

    deinit {
        release()
    }

    func render(
        frame: UInt64,
        acquire: RawGraphicsTestTimeline,
        acquirePoint: UInt64,
        release: RawGraphicsTestTimeline? = nil,
        releasePoint: UInt64 = 0
    ) throws {
        guard let handle = unsafe handle else {
            throw RawGraphicsTestError(description: "buffer was already released")
        }
        var error = [CChar](repeating: 0, count: 1_024)
        guard unsafe nucleus_android_gpu_buffer_render(
            handle,
            frame,
            acquire.handle,
            acquirePoint,
            release?.handle,
            releasePoint,
            &error,
            error.count) == 0
        else {
            throw RawGraphicsTestError(
                description: error.withUnsafeBufferPointer {
                    unsafe String(cString: $0.baseAddress!)
                })
        }
    }

    func release() {
        guard let handle = unsafe handle else { return }
        unsafe self.handle = nil
        unsafe nucleus_android_gpu_buffer_destroy(handle)
    }

    func lastUseSerial() -> UInt64 {
        guard let handle = unsafe handle else { return 0 }
        return unsafe nucleus_android_test_gpu_buffer_last_use_serial(handle)
    }

    func hasGeneralLayout() -> Bool {
        guard let handle = unsafe handle else { return false }
        return unsafe nucleus_android_test_gpu_buffer_has_general_layout(handle) == 1
    }
}

@Test func drmDiscoveryReturnsStableNodeAndPciIdentity() throws {
    let candidates = try DrmDeviceDiscovery.enumerate()
    for candidate in candidates {
        #expect(candidate.renderNode.hasPrefix("/dev/dri/renderD"))
        #expect(candidate.renderDevice.major > 0)
        #expect(candidate.pci.address.count == 12)
        #expect(candidate.matches(candidate.renderDevice))
        if let primary = candidate.primaryDevice {
            #expect(candidate.matches(primary))
        }
    }
}

@Test func selectedHardwareVulkanDeviceMatchesTheDrmRenderNode() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let device = try AndroidGraphicsDevice(candidate: candidate)
    #expect(device.diagnostic.renderDevice == candidate.renderDevice)
    #expect(device.diagnostic.hardwareDriver)
    #expect(!device.diagnostic.vulkanDeviceName.isEmpty)
    #expect(!device.diagnostic.vulkanDriverName.isEmpty)
    #expect(device.diagnostic.vulkanDeviceUUID.count == 32)
    #expect(!device.diagnostic.gbmBackend.isEmpty)
}

@Test func brokerAllocatesRendersAndSignalsAnExplicitAcquirePoint() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let device = try AndroidGraphicsDevice(candidate: candidate)
    let pair = try #require(device.formatModifiers(format: DrmFormats.xrgb8888)
        .map(\.pair)
        .first(where: device.supports))
    let feedback = WaylandDmabufFeedback(
        mainDevice: candidate.renderDevice,
        tranches: [
            WaylandDmabufTranche(
                targetDevice: candidate.renderDevice,
                scanout: false,
                formats: [pair])
        ])
    let ring = try device.allocate(BufferAllocationRequest(
        width: 64,
        height: 64,
        feedback: feedback))
    #expect(ring.buffers.count == 3)
    #expect(ring.buffers.allSatisfy { $0.planeCount == 1 })
    let plane = try ring.buffers[0].exportPlane(at: 0)
    #expect(plane.stride >= 64 * 4)
    let planeFD = plane.takeFileDescriptor()
    #expect(planeFD >= 0)
    _ = close(planeFD)

    try ring.buffers[0].render(
        frameNumber: 1,
        acquireTimeline: ring.acquireTimeline,
        acquirePoint: 1)
    var signaled = ring.acquireTimeline.isSignaled(point: 1) == true
    for _ in 0..<1_000 where !signaled {
        _ = usleep(100)
        signaled = ring.acquireTimeline.isSignaled(point: 1) == true
    }
    #expect(signaled)
}

@Test func threeBufferReuseMaintainsAcquireReleaseTimelineOrdering() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let device = try AndroidGraphicsDevice(candidate: candidate)
    let pair = try #require(device.formatModifiers(format: DrmFormats.xrgb8888)
        .map(\.pair)
        .first(where: device.supports))
    let feedback = WaylandDmabufFeedback(
        mainDevice: candidate.renderDevice,
        tranches: [
            WaylandDmabufTranche(
                targetDevice: candidate.renderDevice,
                scanout: false,
                formats: [pair])
        ])
    let ring = try device.allocate(BufferAllocationRequest(
        width: 64,
        height: 64,
        feedback: feedback))
    var releases: [UInt64: UInt64] = [:]
    for frame in UInt64(1)...120 {
        let buffer = ring.buffers[Int((frame - 1) % 3)]
        let releaseTimeline = try #require(ring.releaseTimeline(for: buffer.id))
        if let priorRelease = releases[buffer.id] {
            #expect(releaseTimeline.signal(point: priorRelease))
        }
        let acquirePoint = frame * 2 - 1
        let releasePoint = acquirePoint + 1
        try buffer.render(
            frameNumber: frame,
            acquireTimeline: ring.acquireTimeline,
            acquirePoint: acquirePoint,
            releaseTimeline: releases[buffer.id] == nil ? nil : releaseTimeline,
            releasePoint: releases[buffer.id] ?? 0)
        releases[buffer.id] = releasePoint
    }
    var finalAcquireSignaled = ring.acquireTimeline.isSignaled(point: 239) == true
    for _ in 0..<2_000 where !finalAcquireSignaled {
        _ = usleep(100)
        finalAcquireSignaled = ring.acquireTimeline.isSignaled(point: 239) == true
    }
    #expect(finalAcquireSignaled)
}

@Test func releaseTimelineSignalsAPollableEventfdWithoutFenceWaiting() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let device = try AndroidGraphicsDevice(candidate: candidate)
    let pair = try #require(device.formatModifiers(format: DrmFormats.xrgb8888)
        .map(\.pair)
        .first(where: device.supports))
    let ring = try device.allocate(BufferAllocationRequest(
        width: 32,
        height: 32,
        feedback: WaylandDmabufFeedback(
            mainDevice: candidate.renderDevice,
            tranches: [
                WaylandDmabufTranche(
                    targetDevice: candidate.renderDevice,
                    scanout: false,
                    formats: [pair])
            ])))
    let timeline = try #require(ring.releaseTimeline(for: 1))
    let timelineFD = try timeline.exportFileDescriptor()
    defer { _ = close(timelineFD) }
    let rawWaiter = candidate.renderNode.withCString { path in
        unsafe nucleus_android_syncobj_waiter_create(path, timelineFD)
    }
    guard let waiter = unsafe rawWaiter else {
        throw RawGraphicsTestError(description: "syncobj waiter creation failed")
    }
    defer { unsafe nucleus_android_syncobj_waiter_destroy(waiter) }
    let armResult = unsafe nucleus_android_syncobj_waiter_arm(waiter, 9)
    #expect(armResult == 0)
    var descriptor = pollfd(
        fd: unsafe nucleus_android_syncobj_waiter_notification_fd(waiter),
        events: Int16(POLLIN),
        revents: 0)
    let beforeSignalPoll = unsafe poll(&descriptor, 1, 0)
    #expect(beforeSignalPoll == 0)
    #expect(timeline.signal(point: 9))
    let afterSignalPoll = unsafe poll(&descriptor, 1, 1_000)
    #expect(afterSignalPoll == 1)
    let drainResult = unsafe nucleus_android_syncobj_waiter_drain(waiter)
    #expect(drainResult == 0)
    let isSignaled = unsafe nucleus_android_syncobj_waiter_is_signaled(
        waiter,
        9)
    #expect(isSignaled == 1)
}

@Test func releaseBridgeMaterializesFutureTimelinePointAsSyncFile() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    var bridgeError = [CChar](repeating: 0, count: 1_024)
    let bridge = candidate.renderNode.withCString { path in
        unsafe nucleus_android_syncobj_bridge_create(
            path, &bridgeError, bridgeError.count)
    }
    guard let bridge = unsafe bridge else {
        throw RawGraphicsTestError(
            description: bridgeError.withUnsafeBufferPointer {
                unsafe String(cString: $0.baseAddress!)
            })
    }
    defer { unsafe nucleus_android_syncobj_bridge_destroy(bridge) }

    var error = [CChar](repeating: 0, count: 1_024)
    let gpu = candidate.renderNode.withCString { path in
        unsafe nucleus_android_gpu_create(path, &error, error.count)
    }
    guard let gpu = unsafe gpu else {
        throw RawGraphicsTestError(
            description: error.withUnsafeBufferPointer {
                unsafe String(cString: $0.baseAddress!)
            })
    }
    defer { unsafe nucleus_android_gpu_destroy(gpu) }

    let timelineFD = unsafe nucleus_android_syncobj_bridge_export_release_timeline(
        bridge)
    guard timelineFD >= 0 else {
        throw RawGraphicsTestError(
            description: "release timeline export failed")
    }
    guard let timeline = unsafe nucleus_android_syncobj_timeline_import_fd(
        gpu, timelineFD)
    else {
        _ = close(timelineFD)
        throw RawGraphicsTestError(
            description: "release timeline import failed")
    }
    _ = close(timelineFD)
    defer { unsafe nucleus_android_syncobj_timeline_destroy(timeline) }

    var releaseError = [CChar](repeating: 0, count: 1_024)
    let releaseFence = unsafe nucleus_android_syncobj_bridge_export_release_sync_file(
        bridge, 7, &releaseError, releaseError.count)
    guard releaseFence >= 0 else {
        throw RawGraphicsTestError(
            description: releaseError.withUnsafeBufferPointer {
                unsafe String(cString: $0.baseAddress!)
            })
    }
    defer { _ = close(releaseFence) }
    let nextReleaseFence =
        unsafe nucleus_android_syncobj_bridge_export_release_sync_file(
            bridge, 8, &releaseError, releaseError.count)
    guard nextReleaseFence >= 0 else {
        throw RawGraphicsTestError(
            description: releaseError.withUnsafeBufferPointer {
                unsafe String(cString: $0.baseAddress!)
            })
    }
    defer { _ = close(nextReleaseFence) }

    var descriptor = pollfd(
        fd: releaseFence,
        events: Int16(POLLIN),
        revents: 0)
    var nextDescriptor = pollfd(
        fd: nextReleaseFence,
        events: Int16(POLLIN),
        revents: 0)
    #expect(unsafe poll(&descriptor, 1, 0) == 0)
    #expect(unsafe poll(&nextDescriptor, 1, 0) == 0)
    #expect(unsafe nucleus_android_syncobj_timeline_signal(timeline, 7) == 0)
    var notification = pollfd(
        fd: unsafe nucleus_android_syncobj_bridge_release_notification_fd(
            bridge),
        events: Int16(POLLIN),
        revents: 0)
    #expect(unsafe poll(&notification, 1, 1_000) == 1)
    #expect(unsafe nucleus_android_syncobj_bridge_dispatch_releases(
        bridge) == 0)
    #expect(unsafe poll(&descriptor, 1, 1_000) == 1)
    #expect(unsafe poll(&nextDescriptor, 1, 0) == 0)
    #expect(unsafe nucleus_android_syncobj_timeline_signal(timeline, 8) == 0)
    notification.revents = 0
    #expect(unsafe poll(&notification, 1, 1_000) == 1)
    #expect(unsafe nucleus_android_syncobj_bridge_dispatch_releases(
        bridge) == 0)
    #expect(unsafe poll(&nextDescriptor, 1, 1_000) == 1)
}

@Test func nativeFenceExportsUnsignaledSyncFileThenSignalsIt() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let gpu = try RawGraphicsTestGPU(candidate: candidate)
    var syncFile: Int32 = -1
    var error = [CChar](repeating: 0, count: 1_024)
    guard let nativeFence = unsafe nucleus_android_native_fence_create(
        gpu.handle,
        &syncFile,
        &error,
        error.count)
    else {
        throw RawGraphicsTestError(
            description: error.withUnsafeBufferPointer {
                unsafe String(cString: $0.baseAddress!)
            })
    }
    defer {
        unsafe nucleus_android_native_fence_destroy(nativeFence)
        _ = close(syncFile)
    }

    var descriptor = pollfd(
        fd: syncFile,
        events: Int16(POLLIN),
        revents: 0)
    #expect(unsafe poll(&descriptor, 1, 0) == 0)
    #expect(unsafe nucleus_android_native_fence_signal(
        nativeFence,
        &error,
        error.count) == 0)
    #expect(unsafe poll(&descriptor, 1, 1_000) == 1)
}

@Test func neverSubmittedBufferIsReclaimedWhileGPUStaysAlive() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let gpu = try RawGraphicsTestGPU(candidate: candidate)
    let baseline = try gpu.diagnostic()
    let buffer = try RawGraphicsTestBuffer(gpu: gpu)

    let allocated = try gpu.diagnostic()
    #expect(allocated.live_buffer_count == baseline.live_buffer_count + 1)
    #expect(allocated.retired_buffer_count == baseline.retired_buffer_count)

    buffer.release()

    let reclaimed = try gpu.diagnostic()
    #expect(reclaimed.live_buffer_count == baseline.live_buffer_count)
    #expect(reclaimed.retired_buffer_count == baseline.retired_buffer_count)
    #expect(reclaimed.reclaimed_buffer_count == baseline.reclaimed_buffer_count + 1)
}

@Test func inFlightBufferIsReclaimedOnlyAfterItsFenceSignals() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let gpu = try RawGraphicsTestGPU(candidate: candidate)
    let acquire = try RawGraphicsTestTimeline(gpu: gpu)
    let baseline = try gpu.diagnostic()
    let buffer = try RawGraphicsTestBuffer(gpu: gpu)
    gpu.forceFencesPending(true)
    defer { gpu.forceFencesPending(false) }

    try buffer.render(
        frame: 1,
        acquire: acquire,
        acquirePoint: 40)
    buffer.release()

    let retired = try gpu.diagnostic()
    #expect(retired.live_buffer_count == baseline.live_buffer_count + 1)
    #expect(retired.retired_buffer_count == baseline.retired_buffer_count + 1)
    #expect(retired.submitted_serial == baseline.submitted_serial + 1)
    #expect(retired.completed_serial == baseline.completed_serial)

    gpu.forceFencesPending(false)
    var acquireSignaled = acquire.isSignaled(40)
    for _ in 0..<2_000 where !acquireSignaled {
        _ = usleep(100)
        acquireSignaled = acquire.isSignaled(40)
    }
    #expect(acquireSignaled)

    var reclaimed = try gpu.diagnostic()
    for _ in 0..<2_000 where reclaimed.live_buffer_count != baseline.live_buffer_count {
        try gpu.collect()
        _ = usleep(100)
        reclaimed = try gpu.diagnostic()
    }
    #expect(reclaimed.live_buffer_count == baseline.live_buffer_count)
    #expect(reclaimed.retired_buffer_count == baseline.retired_buffer_count)
    #expect(reclaimed.reclaimed_buffer_count == baseline.reclaimed_buffer_count + 1)
    #expect(reclaimed.completed_serial == reclaimed.submitted_serial)
    #expect(reclaimed.terminal_submission_result == 0)
}

@Test func postSubmitFailurePreservesSubmittedBufferState() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let gpu = try RawGraphicsTestGPU(candidate: candidate)
    let acquire = try RawGraphicsTestTimeline(gpu: gpu)
    let baseline = try gpu.diagnostic()
    let buffer = try RawGraphicsTestBuffer(gpu: gpu)
    gpu.forceFencesPending(true)
    defer { gpu.forceFencesPending(false) }
    gpu.failNextPostSubmitStep()

    #expect(throws: RawGraphicsTestError.self) {
        try buffer.render(
            frame: 1,
            acquire: acquire,
            acquirePoint: 1)
    }

    let submitted = try gpu.diagnostic()
    #expect(submitted.submitted_serial == baseline.submitted_serial + 1)
    #expect(submitted.completed_serial == baseline.completed_serial)
    #expect(buffer.lastUseSerial() == submitted.submitted_serial)
    #expect(buffer.hasGeneralLayout())

    buffer.release()
    let retired = try gpu.diagnostic()
    #expect(retired.live_buffer_count == baseline.live_buffer_count + 1)
    #expect(retired.retired_buffer_count == baseline.retired_buffer_count + 1)

    gpu.forceFencesPending(false)
    var reclaimed = try gpu.diagnostic()
    for _ in 0..<2_000 where reclaimed.live_buffer_count != baseline.live_buffer_count {
        try gpu.collect()
        _ = usleep(100)
        reclaimed = try gpu.diagnostic()
    }
    #expect(reclaimed.live_buffer_count == baseline.live_buffer_count)
    #expect(reclaimed.retired_buffer_count == baseline.retired_buffer_count)
    #expect(reclaimed.reclaimed_buffer_count == baseline.reclaimed_buffer_count + 1)
    #expect(reclaimed.completed_serial == reclaimed.submitted_serial)
}

@Test func repeatedRenderReleaseCyclesReturnLiveBuffersToBaseline() throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let gpu = try RawGraphicsTestGPU(candidate: candidate)
    let acquire = try RawGraphicsTestTimeline(gpu: gpu)
    let baseline = try gpu.diagnostic()

    for frame in UInt64(1)...32 {
        let buffer = try RawGraphicsTestBuffer(gpu: gpu)
        try buffer.render(
            frame: frame,
            acquire: acquire,
            acquirePoint: frame)
        var signaled = acquire.isSignaled(frame)
        for _ in 0..<2_000 where !signaled {
            _ = usleep(100)
            signaled = acquire.isSignaled(frame)
        }
        #expect(signaled)
        buffer.release()
        try gpu.collect()
    }

    let reclaimed = try gpu.diagnostic()
    #expect(reclaimed.live_buffer_count == baseline.live_buffer_count)
    #expect(reclaimed.retired_buffer_count == baseline.retired_buffer_count)
    #expect(reclaimed.reclaimed_buffer_count == baseline.reclaimed_buffer_count + 32)
    #expect(reclaimed.completed_serial == reclaimed.submitted_serial)
}

@Test func concurrentRendersAndReleasesShareOneGPULifetimeDomain() async throws {
    guard let candidate = try DrmDeviceDiscovery.enumerate().first else { return }
    let gpu = try RawGraphicsTestGPU(candidate: candidate)
    let acquire = try RawGraphicsTestTimeline(gpu: gpu)
    let baseline = try gpu.diagnostic()
    let buffers = try (0..<24).map { _ in
        try RawGraphicsTestBuffer(gpu: gpu)
    }

    let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
        for (index, buffer) in buffers.enumerated() {
            group.addTask {
                do {
                    try buffer.render(
                        frame: UInt64(index + 1),
                        acquire: acquire,
                        acquirePoint: UInt64(index + 1))
                    buffer.release()
                    return nil
                } catch {
                    buffer.release()
                    return String(describing: error)
                }
            }
        }
        var failures: [String] = []
        for await failure in group {
            if let failure {
                failures.append(failure)
            }
        }
        return failures
    }
    #expect(failures.isEmpty)

    var reclaimed = try gpu.diagnostic()
    for _ in 0..<4_000 where reclaimed.live_buffer_count != baseline.live_buffer_count {
        try gpu.collect()
        _ = usleep(100)
        reclaimed = try gpu.diagnostic()
    }
    #expect(reclaimed.live_buffer_count == baseline.live_buffer_count)
    #expect(reclaimed.retired_buffer_count == baseline.retired_buffer_count)
    #expect(reclaimed.reclaimed_buffer_count == baseline.reclaimed_buffer_count + 24)
    #expect(reclaimed.submitted_serial == baseline.submitted_serial + 24)
    #expect(reclaimed.completed_serial == reclaimed.submitted_serial)
    #expect(reclaimed.terminal_submission_result == 0)
}
