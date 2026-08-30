import NucleusCompositorWindowScene
import NucleusLayers
import Testing
import WaylandProtocolTypes

@testable import NucleusCompositorWaylandRuntime

@MainActor
@Suite(.serialized)
struct TabletV2WireTests {
    @Test func tabletToolAndPadProjectCompleteClientLifecycles() throws {
        let graph = WaylandTestGraph()
        defer { withExtendedLifetime(graph) {} }
        let runtime = try #require(
            graph.routerRuntime(
                author: WindowSceneAuthor(commitSinkFactory: { InMemoryCommitSink() })))
        let client = try #require(WaylandTestClient(display: runtime.router.display))
        let globals = client.globals()

        func global(_ interface: String) throws -> (UInt32, UInt32) {
            let global = try #require(globals.first { $0.interface == interface })
            return (global.name, global.version)
        }

        let compositorGlobal = try global("wl_compositor")
        let seatGlobal = try global("wl_seat")
        let tabletGlobal = try global("zwp_tablet_manager_v2")
        let compositorID: UInt32 = 3
        let seatID: UInt32 = 4
        let managerID: UInt32 = 5
        let surfaceID: UInt32 = 6
        let secondSurfaceID: UInt32 = 7
        let tabletSeatID: UInt32 = 8

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
            $0.uint(tabletGlobal.0)
            $0.string("zwp_tablet_manager_v2")
            $0.uint(tabletGlobal.1)
            $0.newId(managerID)
        }
        setup.request(object: compositorID, opcode: WlCompositorRequestOpcode.createSurface) {
            $0.newId(surfaceID)
        }
        setup.request(object: compositorID, opcode: WlCompositorRequestOpcode.createSurface) {
            $0.newId(secondSurfaceID)
        }
        setup.request(
            object: managerID,
            opcode: ZwpTabletManagerV2RequestOpcode.getTabletSeat
        ) {
            $0.newId(tabletSeatID)
            $0.object(seatID)
        }
        #expect(client.send(setup))
        client.pump()
        _ = client.drainEvents()

        let surface = try #require(
            runtime.compositor.liveSurfaceIDs.lazy
                .compactMap { runtime.compositor.surface(id: $0) }
                .first { $0.protocolResource?.objectID == surfaceID })
        let secondSurface = try #require(
            runtime.compositor.liveSurfaceIDs.lazy
                .compactMap { runtime.compositor.surface(id: $0) }
                .first { $0.protocolResource?.objectID == secondSurfaceID })
        let tabletID = TabletDeviceID(rawValue: 500)
        let padID = TabletDeviceID(rawValue: 501)
        let tablet = TabletDeviceDescriptor(
            id: tabletID, groupID: 900,
            name: "Nucleus test tablet", vendorID: 0x1234, productID: 0x5678,
            path: "/dev/input/event-test-tablet")
        let pad = TabletPadDescriptor(
            device: TabletDeviceDescriptor(
                id: padID, groupID: 900,
                name: "Nucleus test pad", vendorID: 0x1234, productID: 0x5679,
                path: "/dev/input/event-test-pad"),
            buttonCount: 2, ringCount: 0, stripCount: 0, dialCount: 0,
            groups: [
                TabletPadGroupDescriptor(
                    index: 0, modeCount: 2, buttons: [0, 1],
                    rings: [], strips: [], dials: [])
            ])
        let tool = TabletToolDescriptor(
            id: TabletToolID(rawValue: 700), kind: .pen,
            serial: 0x1122_3344_5566_7788,
            hardwareID: 0x8877_6655_4433_2211,
            capabilities: [.pressure, .tilt])

        runtime.tablet.addTablet(tablet)
        runtime.tablet.addPad(pad)
        runtime.tablet.handle(
            .proximityIn(
                deviceID: tabletID, tool: tool, timestampNs: 1_000_000,
                axes: TabletAxes(x: 10, y: 20, pressure: 0.25)),
            resolveTarget: { _ in
                TabletManager.Target(surface: surface, localX: 3.5, localY: 4.5)
            })
        runtime.tablet.handle(
            .axes(
                deviceID: tabletID, toolID: tool.id, timestampNs: 1_500_000,
                axes: TabletAxes(x: 30, y: 40, pressure: 0.4)),
            resolveTarget: { _ in
                TabletManager.Target(surface: secondSurface, localX: 6.5, localY: 7.5)
            })
        runtime.tablet.handle(
            .tip(
                deviceID: tabletID, toolID: tool.id, timestampNs: 2_000_000,
                down: true, axes: TabletAxes(pressure: 0.5)))
        runtime.tablet.handle(
            .toolButton(
                deviceID: tabletID, toolID: tool.id, timestampNs: 3_000_000,
                button: 0x14b, down: true, axes: TabletAxes()))
        runtime.tablet.handle(
            .padButton(
                deviceID: padID, timestampNs: 4_000_000,
                button: 1, down: true, group: 0, mode: 1))
        runtime.tablet.handle(
            .proximityOut(
                deviceID: tabletID, toolID: tool.id, timestampNs: 5_000_000))
        runtime.tablet.removeDevice(padID)
        runtime.tablet.removeDevice(tabletID)

        runtime.router.flushClients()
        let events = client.drainEvents()
        let tabletAdded = try #require(
            WireMessage.first(events, object: tabletSeatID, opcode: 0))
        let tabletObjectID = tabletAdded.u32(0)
        let padAdded = try #require(
            WireMessage.first(events, object: tabletSeatID, opcode: 2))
        let padObjectID = padAdded.u32(0)
        let toolAdded = try #require(
            WireMessage.first(events, object: tabletSeatID, opcode: 1))
        let toolObjectID = toolAdded.u32(0)

        #expect(WireMessage.first(events, object: tabletObjectID, opcode: 0) != nil)
        #expect(WireMessage.first(events, object: tabletObjectID, opcode: 1)?.u32(0) == 0x1234)
        #expect(WireMessage.first(events, object: tabletObjectID, opcode: 3) != nil)
        #expect(WireMessage.first(events, object: tabletObjectID, opcode: 4) != nil)

        #expect(WireMessage.first(events, object: toolObjectID, opcode: 0)?.u32(0) == 0x140)
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 4) != nil)
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 6) != nil)
        #expect(events.filter { $0.objectId == toolObjectID && $0.opcode == 6 }.count == 2)
        let motion = try #require(
            WireMessage.first(events, object: toolObjectID, opcode: 10))
        #expect(motion.i32(0) == Int32((3.5 * 256).rounded()))
        #expect(motion.i32(4) == Int32((4.5 * 256).rounded()))
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 8) != nil)
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 17) != nil)
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 9) != nil)
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 7) != nil)
        #expect(WireMessage.first(events, object: toolObjectID, opcode: 5) != nil)

        #expect(WireMessage.first(events, object: padObjectID, opcode: 2)?.u32(0) == 2)
        #expect(WireMessage.first(events, object: padObjectID, opcode: 3) != nil)
        #expect(WireMessage.first(events, object: padObjectID, opcode: 5) != nil)
        #expect(events.filter { $0.objectId == padObjectID && $0.opcode == 5 }.count == 2)
        #expect(WireMessage.first(events, object: padObjectID, opcode: 4) != nil)
        #expect(WireMessage.first(events, object: padObjectID, opcode: 6) != nil)
        #expect(WireMessage.first(events, object: padObjectID, opcode: 7) != nil)

        #expect(runtime.tablet.activeBindingCount == 1)
        var teardown = WireBuilder()
        teardown.request(object: tabletSeatID, opcode: ZwpTabletSeatV2RequestOpcode.destroy) { _ in
        }
        #expect(client.send(teardown))
        client.pump()
        #expect(runtime.tablet.activeBindingCount == 0)
    }
}
