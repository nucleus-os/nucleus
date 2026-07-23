import Glibc
import Testing
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
@testable import NucleusAndroidGraphicsPlatform

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
        nucleus_android_syncobj_waiter_create(path, timelineFD)
    }
    let waiter = try #require(rawWaiter)
    defer { nucleus_android_syncobj_waiter_destroy(waiter) }
    #expect(nucleus_android_syncobj_waiter_arm(waiter, 9) == 0)
    var descriptor = pollfd(
        fd: nucleus_android_syncobj_waiter_notification_fd(waiter),
        events: Int16(POLLIN),
        revents: 0)
    #expect(poll(&descriptor, 1, 0) == 0)
    #expect(timeline.signal(point: 9))
    #expect(poll(&descriptor, 1, 1_000) == 1)
    #expect(nucleus_android_syncobj_waiter_drain(waiter) == 0)
    #expect(nucleus_android_syncobj_waiter_is_signaled(waiter, 9) == 1)
}
