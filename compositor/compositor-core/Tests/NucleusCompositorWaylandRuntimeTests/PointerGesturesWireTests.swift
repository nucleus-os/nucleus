import NucleusCompositorServerTypes
import NucleusCompositorWindowScene
import NucleusLayers
import Testing
import WaylandProtocolTypes

@testable import NucleusCompositorWaylandRuntime

@MainActor
private struct PointerGestureWireContext {
    let client: WaylandTestClient
    let surface: WlSurface
    let pointerID: UInt32
    let managerID: UInt32
    let swipeID: UInt32
    let pinchID: UInt32
    let holdID: UInt32
    let runtime: WaylandRouterRuntime
    let graph: WaylandTestGraph
}

@MainActor
private func pointerGestureSurface(
    in compositor: WlCompositor,
    wireID: UInt32
) -> WlSurface? {
    compositor.liveSurfaceIDs.lazy
        .compactMap { compositor.surface(id: $0) }
        .first { $0.protocolResource?.objectID == wireID }
}

@MainActor
private func pointerGestureContext() throws -> PointerGestureWireContext {
    let graph = WaylandTestGraph()
    let runtime = try #require(
        graph.routerRuntime(author: WindowSceneAuthor(commitSinkFactory: { InMemoryCommitSink() })))
    runtime.seat.updateCapabilities(pointer: true, keyboard: false, touch: false)
    let client = try #require(WaylandTestClient(display: runtime.router.display))
    let globals = client.globals()

    func global(_ interface: String) throws -> (UInt32, UInt32) {
        let global = try #require(globals.first { $0.interface == interface })
        return (global.name, global.version)
    }

    let compositorGlobal = try global("wl_compositor")
    let seatGlobal = try global("wl_seat")
    let gesturesGlobal = try global("zwp_pointer_gestures_v1")
    let compositorID: UInt32 = 3
    let seatID: UInt32 = 4
    let managerID: UInt32 = 5
    let surfaceID: UInt32 = 6
    let pointerID: UInt32 = 7
    let swipeID: UInt32 = 8
    let pinchID: UInt32 = 9
    let holdID: UInt32 = 10

    var setup = WireBuilder()
    setup.request(object: 2, opcode: WlRegistryRequestOpcode.bind) {
        $0.uint(compositorGlobal.0)
        $0.string("wl_compositor")
        $0.uint(compositorGlobal.1)
        $0.newId(compositorID)
    }
    setup.request(object: 2, opcode: WlRegistryRequestOpcode.bind) {
        $0.uint(seatGlobal.0)
        $0.string("wl_seat")
        $0.uint(seatGlobal.1)
        $0.newId(seatID)
    }
    setup.request(object: 2, opcode: WlRegistryRequestOpcode.bind) {
        $0.uint(gesturesGlobal.0)
        $0.string("zwp_pointer_gestures_v1")
        $0.uint(gesturesGlobal.1)
        $0.newId(managerID)
    }
    setup.request(object: compositorID, opcode: WlCompositorRequestOpcode.createSurface) {
        $0.newId(surfaceID)
    }
    setup.request(object: seatID, opcode: WlSeatRequestOpcode.getPointer) {
        $0.newId(pointerID)
    }
    setup.request(object: managerID, opcode: ZwpPointerGesturesV1RequestOpcode.getSwipeGesture) {
        $0.newId(swipeID)
        $0.object(pointerID)
    }
    setup.request(object: managerID, opcode: ZwpPointerGesturesV1RequestOpcode.getPinchGesture) {
        $0.newId(pinchID)
        $0.object(pointerID)
    }
    setup.request(object: managerID, opcode: ZwpPointerGesturesV1RequestOpcode.getHoldGesture) {
        $0.newId(holdID)
        $0.object(pointerID)
    }
    #expect(client.send(setup))
    client.pump()
    _ = client.drainEvents()

    let surface = try #require(
        pointerGestureSurface(in: runtime.compositor, wireID: surfaceID))
    #expect(runtime.seat.pointerEnter(surface, surfaceX: 3, surfaceY: 4) != 0)
    runtime.router.flushClients()
    _ = client.drainEvents()
    return PointerGestureWireContext(
        client: client,
        surface: surface,
        pointerID: pointerID,
        managerID: managerID,
        swipeID: swipeID,
        pinchID: pinchID,
        holdID: holdID,
        runtime: runtime,
        graph: graph)
}

private func fixed(_ value: Double) -> Int32 {
    Int32((value * 256).rounded())
}

@MainActor
private struct PointerGestureServerSurvivors {
    let manager: PointerGestureManager
    let runtime: WaylandRouterRuntime
    let graph: WaylandTestGraph
    let sequence: NormalizedGestureSequence
}

@MainActor
private func disconnectClientDuringSwipe() throws -> PointerGestureServerSurvivors {
    let context = try pointerGestureContext()
    let manager = try #require(context.runtime.seat.pointerGestures)
    let sequence = NormalizedGestureSequence(
        deviceID: NormalizedGestureDeviceID(rawValue: 401),
        kind: .swipe,
        fingerCount: 3)
    manager.handle(.began(sequence: sequence, timestampNs: 30_000_000))
    context.runtime.router.flushClients()
    _ = context.client.drainEvents()
    return PointerGestureServerSurvivors(
        manager: manager,
        runtime: context.runtime,
        graph: context.graph,
        sequence: sequence)
}

@MainActor
@Suite(.serialized)
struct PointerGesturesWireTests {
    @Test func swipePinchAndHoldDeliverTheirCompleteWireLifecycles() throws {
        let context = try pointerGestureContext()
        let manager = try #require(context.runtime.seat.pointerGestures)
        let device = NormalizedGestureDeviceID(rawValue: 101)

        let swipe = NormalizedGestureSequence(
            deviceID: device, kind: .swipe, fingerCount: 3)
        manager.handle(.began(sequence: swipe, timestampNs: 1_000_000))
        manager.handle(
            .swipeUpdated(
                sequence: swipe,
                timestampNs: 2_000_000,
                deltaX: 1.25,
                deltaY: -2.5))
        manager.handle(.ended(sequence: swipe, timestampNs: 3_000_000, cancelled: false))

        let pinch = NormalizedGestureSequence(
            deviceID: device, kind: .pinch, fingerCount: 4)
        manager.handle(.began(sequence: pinch, timestampNs: 4_000_000))
        manager.handle(
            .pinchUpdated(
                sequence: pinch,
                timestampNs: 5_000_000,
                deltaX: -3,
                deltaY: 2,
                scale: 1.5,
                rotationDegrees: 12.25))
        manager.handle(.ended(sequence: pinch, timestampNs: 6_000_000, cancelled: true))

        let hold = NormalizedGestureSequence(
            deviceID: device, kind: .hold, fingerCount: 2)
        manager.handle(.began(sequence: hold, timestampNs: 7_000_000))
        manager.handle(.ended(sequence: hold, timestampNs: 8_000_000, cancelled: false))

        context.runtime.router.flushClients()
        let events = context.client.drainEvents()
        let swipeBegin = try #require(
            WireMessage.first(events, object: context.swipeID, opcode: 0))
        #expect(swipeBegin.u32(4) == 1)
        #expect(swipeBegin.u32(8) == context.surface.protocolResource?.objectID)
        #expect(swipeBegin.u32(12) == 3)
        let swipeUpdate = try #require(
            WireMessage.first(events, object: context.swipeID, opcode: 1))
        #expect(swipeUpdate.u32(0) == 2)
        #expect(swipeUpdate.i32(4) == fixed(1.25))
        #expect(swipeUpdate.i32(8) == fixed(-2.5))
        let swipeEnd = try #require(
            WireMessage.first(events, object: context.swipeID, opcode: 2))
        #expect(swipeEnd.u32(4) == 3)
        #expect(swipeEnd.i32(8) == 0)

        let pinchUpdate = try #require(
            WireMessage.first(events, object: context.pinchID, opcode: 1))
        #expect(pinchUpdate.u32(0) == 5)
        #expect(pinchUpdate.i32(4) == fixed(-3))
        #expect(pinchUpdate.i32(8) == fixed(2))
        #expect(pinchUpdate.i32(12) == fixed(1.5))
        #expect(pinchUpdate.i32(16) == fixed(12.25))
        let pinchEnd = try #require(
            WireMessage.first(events, object: context.pinchID, opcode: 2))
        #expect(pinchEnd.u32(4) == 6)
        #expect(pinchEnd.i32(8) == 1)

        let holdBegin = try #require(
            WireMessage.first(events, object: context.holdID, opcode: 0))
        #expect(holdBegin.u32(4) == 7)
        #expect(holdBegin.u32(12) == 2)
        let holdEnd = try #require(
            WireMessage.first(events, object: context.holdID, opcode: 1))
        #expect(holdEnd.u32(4) == 8)
        #expect(holdEnd.i32(8) == 0)
    }

    @Test func focusTransferAndSecondDeviceCancelExactlyOnce() throws {
        let context = try pointerGestureContext()
        let manager = try #require(context.runtime.seat.pointerGestures)
        let first = NormalizedGestureSequence(
            deviceID: NormalizedGestureDeviceID(rawValue: 201),
            kind: .swipe,
            fingerCount: 3)
        let second = NormalizedGestureSequence(
            deviceID: NormalizedGestureDeviceID(rawValue: 202),
            kind: .swipe,
            fingerCount: 4)

        manager.handle(.began(sequence: first, timestampNs: 10_000_000))
        manager.handle(.began(sequence: second, timestampNs: 11_000_000))
        context.runtime.router.flushClients()
        let replacement = context.client.drainEvents().filter {
            $0.objectId == context.swipeID
        }
        #expect(replacement.map(\.opcode) == [0, 2, 0])
        #expect(replacement[1].i32(8) == 1)

        context.runtime.seat.pointerLeave(context.surface)
        manager.handle(
            .ended(
                sequence: second,
                timestampNs: 12_000_000,
                cancelled: false))
        context.runtime.router.flushClients()
        let focusLoss = context.client.drainEvents().filter {
            $0.objectId == context.swipeID && $0.opcode == 2
        }
        #expect(focusLoss.count == 1)
        #expect(focusLoss[0].i32(8) == 1)
    }

    @Test func destroyingAnActiveResourceRetiresItsDeliveryState() throws {
        let context = try pointerGestureContext()
        let manager = try #require(context.runtime.seat.pointerGestures)
        let first = NormalizedGestureSequence(
            deviceID: NormalizedGestureDeviceID(rawValue: 301),
            kind: .swipe,
            fingerCount: 3)
        manager.handle(.began(sequence: first, timestampNs: 20_000_000))
        context.runtime.router.flushClients()
        _ = context.client.drainEvents()

        var destroy = WireBuilder()
        destroy.request(
            object: context.swipeID,
            opcode: ZwpPointerGestureSwipeV1RequestOpcode.destroy
        ) { _ in }
        #expect(context.client.send(destroy))
        context.client.pump()

        manager.handle(
            .swipeUpdated(
                sequence: first,
                timestampNs: 21_000_000,
                deltaX: 9,
                deltaY: 9))
        manager.handle(.ended(sequence: first, timestampNs: 22_000_000, cancelled: false))
        context.runtime.router.flushClients()
        #expect(context.client.drainEvents().isEmpty)
    }

    @Test func clientDestructionRetiresAnActiveSequence() throws {
        let survivors = try disconnectClientDuringSwipe()
        survivors.manager.handle(
            .swipeUpdated(
                sequence: survivors.sequence,
                timestampNs: 31_000_000,
                deltaX: 1,
                deltaY: 1))
        survivors.manager.handle(
            .ended(
                sequence: survivors.sequence,
                timestampNs: 32_000_000,
                cancelled: false))
        survivors.runtime.router.flushClients()
        withExtendedLifetime(survivors.graph) {}
    }
}
