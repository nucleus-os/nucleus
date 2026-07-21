// Wire-level Wayland protocol conformance tests. Each test drives the real router over the
// in-process `WaylandTestClient` harness and asserts observable protocol behaviour —
// the same gate the parity fixtures use, revived as a swift-testing target.
//
// These cover the fixes that need no client buffer (protocol-error and inert-state
// paths). Buffer-backed cases (already_constructed, dimensions_mismatch, screencopy
// validation) build on the `ShmScratch` helper below.

import Testing
import Glibc
import WaylandServerC
import NucleusCompositorServer
import NucleusCompositorWindowScene
import NucleusLayers
@testable import NucleusCompositorWaylandRuntime

private let testDrmFormatXrgb8888: UInt32 = 0x3432_5258

private final class AcceptingDmabufDelegate: DmabufDelegate {
    func dmabufSupportedFormats() -> [DmabufFormat] {
        [DmabufFormat(format: testDrmFormatXrgb8888, modifier: 0)]
    }
    func dmabufImport(_: DmabufAttrs) -> Bool { true }
    func dmabufMainDevice() -> UInt64 { 0 }
}

@MainActor @Suite(.serialized)
struct WaylandProtocolConformanceTests {

/// A decoded `wl_display.error` (object 1, opcode 0): offending object id, code, message.
private struct WireError {
    let objectID: UInt32
    let code: UInt32
    static func first(_ messages: [WireMessage]) -> WireError? {
        guard let m = WireMessage.first(messages, object: 1, opcode: 0) else { return nil }
        return WireError(objectID: m.u32(0), code: m.u32(4))
    }
}

/// Bind a global discovered on the registry into `b` (registry is object 2).
private func bind(
    _ b: inout WireBuilder, _ iface: String, _ id: UInt32,
    _ globals: [(name: UInt32, interface: String, version: UInt32)]
) throws {
    guard let g = globals.first(where: { $0.interface == iface }) else {
        Issue.record("global \(iface) not advertised"); throw CancellationError()
    }
    b.message(object: 2, opcode: 0) {
        $0.uint(g.name); $0.string(iface); $0.uint(g.version); $0.newId(id)
    }
}

// MARK: - registry contract

/// The production router advertises only protocol versions whose requests and
/// observable behavior Nucleus implements. This wire-visible contract prevents
/// an inert protocol object from becoming discoverable accidentally.
@Test func productionRegistryMatchesSupportedProtocolContract() throws {
    let sink = InMemoryCommitSink()
    let author = WindowSceneAuthor(commitSinkFactory: { sink })
    let runtime = try #require(WaylandRouterRuntime(author: author))
    let client = try #require(WaylandTestClient(display: runtime.router.display))

    let actual = Dictionary(
        uniqueKeysWithValues: client.globals().map { ($0.interface, $0.version) })
    let expected: [String: UInt32] = [
        "wl_compositor": 6,
        "wl_data_device_manager": 3,
        "wl_seat": 9,
        "wl_shm": 2,
        "wl_subcompositor": 1,
        "xdg_activation_v1": 1,
        "xdg_wm_base": 3,
        "zxdg_decoration_manager_v1": 2,
        "zxdg_exporter_v2": 1,
        "zxdg_importer_v2": 1,
        "zxdg_output_manager_v1": 3,
        "wp_cursor_shape_manager_v1": 1,
        "wp_fractional_scale_manager_v1": 1,
        "wp_linux_drm_syncobj_manager_v1": 1,
        "wp_presentation": 2,
        "wp_viewporter": 1,
        "ext_background_effect_manager_v1": 1,
        "ext_data_control_manager_v1": 1,
        "ext_idle_notifier_v1": 2,
        "ext_session_lock_manager_v1": 1,
        "ext_workspace_manager_v1": 1,
        "org_kde_kwin_blur_manager": 1,
        "xwayland_shell_v1": 1,
        "zwlr_foreign_toplevel_manager_v1": 3,
        "zwlr_gamma_control_manager_v1": 1,
        "zwlr_layer_shell_v1": 4,
        "zwlr_screencopy_manager_v1": 3,
        "zwp_idle_inhibit_manager_v1": 1,
        "zwp_keyboard_shortcuts_inhibit_manager_v1": 1,
        "zwp_linux_dmabuf_v1": 5,
        "zwp_pointer_constraints_v1": 1,
        "zwp_relative_pointer_manager_v1": 1,
        "zwp_text_input_manager_v3": 2,
    ]

    #expect(actual == expected)
    #expect(actual["wp_commit_timing_manager_v1"] == nil)
    #expect(actual["wp_fifo_manager_v1"] == nil)
    #expect(actual["wp_tearing_control_manager_v1"] == nil)
}

// MARK: - core surface and XDG construction

@Test func surfaceRejectsInvalidScaleAndTransform() throws {
    func run(opcode: UInt16, value: Int32, expectedCode: UInt32) throws {
        let router = try #require(NucleusWaylandRouter())
        WlCompositor().register(in: router)
        let client = try #require(
            WaylandTestClient(display: router.display))
        let globals = client.globals()
        let compositorID: UInt32 = 3
        let surfaceID: UInt32 = 4
        var request = WireBuilder()
        try bind(
            &request, "wl_compositor", compositorID, globals)
        request.message(object: compositorID, opcode: 0) {
            $0.newId(surfaceID)
        }
        request.message(object: surfaceID, opcode: opcode) {
            $0.int(value)
        }
        #expect(client.send(request))
        client.pump()
        let error = try #require(
            WireError.first(client.drainEvents()))
        #expect(error.objectID == surfaceID)
        #expect(error.code == expectedCode)
    }

    try run(opcode: 8, value: 0, expectedCode: 0)
    try run(opcode: 7, value: 99, expectedCode: 1)
}

@Test func xdgToplevelRejectsSelfParent() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    XdgShell().register(in: router)
    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compositorID: UInt32 = 3
    let wmBaseID: UInt32 = 4
    let surfaceID: UInt32 = 5
    let xdgSurfaceID: UInt32 = 6
    let toplevelID: UInt32 = 7

    var request = WireBuilder()
    try bind(
        &request, "wl_compositor", compositorID, globals)
    try bind(
        &request, "xdg_wm_base", wmBaseID, globals)
    request.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    request.message(object: wmBaseID, opcode: 2) {
        $0.newId(xdgSurfaceID)
        $0.object(surfaceID)
    }
    request.message(object: xdgSurfaceID, opcode: 1) {
        $0.newId(toplevelID)
    }
    request.message(object: toplevelID, opcode: 1) {
        $0.object(toplevelID)
    }
    #expect(client.send(request))
    client.pump()
    let error = try #require(
        WireError.first(client.drainEvents()))
    #expect(error.objectID == toplevelID)
    #expect(error.code == 1)
}

@Test func decorationModeIsBatchedIntoXdgConfigureCycle() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    XdgShell().register(in: router)
    XdgDecorationManager().register(in: router)
    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compositorID: UInt32 = 3
    let wmBaseID: UInt32 = 4
    let decorationManagerID: UInt32 = 5
    let surfaceID: UInt32 = 6
    let xdgSurfaceID: UInt32 = 7
    let toplevelID: UInt32 = 8
    let decorationID: UInt32 = 9

    var setup = WireBuilder()
    try bind(
        &setup, "wl_compositor", compositorID, globals)
    try bind(&setup, "xdg_wm_base", wmBaseID, globals)
    try bind(
        &setup, "zxdg_decoration_manager_v1",
        decorationManagerID, globals)
    setup.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    setup.message(object: wmBaseID, opcode: 2) {
        $0.newId(xdgSurfaceID)
        $0.object(surfaceID)
    }
    setup.message(object: xdgSurfaceID, opcode: 1) {
        $0.newId(toplevelID)
    }
    setup.message(object: decorationManagerID, opcode: 1) {
        $0.newId(decorationID)
        $0.object(toplevelID)
    }
    setup.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(setup))
    client.pump()
    let initial = client.drainEvents()
    #expect(WireMessage.first(
        initial, object: decorationID, opcode: 0)?.u32(0) == 2)

    var mode = WireBuilder()
    mode.message(object: decorationID, opcode: 1) {
        $0.uint(1)
    }
    #expect(client.send(mode))
    client.pump()
    let events = client.drainEvents()
    let decorationIndex = try #require(
        events.firstIndex {
            $0.objectId == decorationID && $0.opcode == 0
        })
    let toplevelIndex = try #require(
        events.firstIndex {
            $0.objectId == toplevelID && $0.opcode == 0
        })
    let surfaceIndex = try #require(
        events.firstIndex {
            $0.objectId == xdgSurfaceID && $0.opcode == 0
        })
    #expect(events[decorationIndex].u32(0) == 1)
    #expect(decorationIndex < toplevelIndex)
    #expect(toplevelIndex < surfaceIndex)
}

@Test func decorationRejectsDuplicateObjectAndInvalidMode() throws {
    func setupClient() throws -> (
        router: NucleusWaylandRouter,
        client: WaylandTestClient,
        managerID: UInt32,
        toplevelID: UInt32,
        decorationID: UInt32
    ) {
        let router = try #require(NucleusWaylandRouter())
        WlCompositor().register(in: router)
        XdgShell().register(in: router)
        XdgDecorationManager().register(in: router)
        let client = try #require(
            WaylandTestClient(display: router.display))
        let globals = client.globals()
        let compositorID: UInt32 = 3
        let wmBaseID: UInt32 = 4
        let managerID: UInt32 = 5
        let surfaceID: UInt32 = 6
        let xdgSurfaceID: UInt32 = 7
        let toplevelID: UInt32 = 8
        let decorationID: UInt32 = 9
        var setup = WireBuilder()
        try bind(
            &setup, "wl_compositor", compositorID, globals)
        try bind(&setup, "xdg_wm_base", wmBaseID, globals)
        try bind(
            &setup, "zxdg_decoration_manager_v1",
            managerID, globals)
        setup.message(object: compositorID, opcode: 0) {
            $0.newId(surfaceID)
        }
        setup.message(object: wmBaseID, opcode: 2) {
            $0.newId(xdgSurfaceID)
            $0.object(surfaceID)
        }
        setup.message(object: xdgSurfaceID, opcode: 1) {
            $0.newId(toplevelID)
        }
        setup.message(object: managerID, opcode: 1) {
            $0.newId(decorationID)
            $0.object(toplevelID)
        }
        #expect(client.send(setup))
        client.pump()
        _ = client.drainEvents()
        return (
            router, client, managerID, toplevelID,
            decorationID)
    }

    do {
        let context = try setupClient()
        var duplicate = WireBuilder()
        duplicate.message(
            object: context.managerID, opcode: 1
        ) {
            $0.newId(10)
            $0.object(context.toplevelID)
        }
        #expect(context.client.send(duplicate))
        context.client.pump()
        let error = try #require(
            WireError.first(context.client.drainEvents()))
        #expect(error.objectID == context.managerID)
        #expect(error.code == 0)
    }

    do {
        let context = try setupClient()
        var invalid = WireBuilder()
        invalid.message(
            object: context.decorationID, opcode: 1
        ) {
            $0.uint(99)
        }
        #expect(context.client.send(invalid))
        context.client.pump()
        let error = try #require(
            WireError.first(context.client.drainEvents()))
        #expect(error.objectID == context.decorationID)
        #expect(error.code == 0)
    }
}

@Test func dataDeviceDragNegotiatesAndFinishesOnTheWire() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    let seat = WlSeat()
    let dataDevice = WlDataDeviceManager(compositor: compositor)
    compositor.register(in: router)
    seat.updateCapabilities(
        pointer: true, keyboard: false, touch: false)
    seat.register(in: router)
    dataDevice.register(in: router)

    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compositorID: UInt32 = 3
    let seatID: UInt32 = 4
    let dataManagerID: UInt32 = 5
    let surfaceID: UInt32 = 6
    let pointerID: UInt32 = 7
    let sourceID: UInt32 = 8
    let deviceID: UInt32 = 9

    var setup = WireBuilder()
    try bind(
        &setup, "wl_compositor", compositorID, globals)
    try bind(&setup, "wl_seat", seatID, globals)
    try bind(
        &setup, "wl_data_device_manager", dataManagerID, globals)
    setup.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    setup.message(object: seatID, opcode: 0) {
        $0.newId(pointerID)
    }
    setup.message(object: dataManagerID, opcode: 0) {
        $0.newId(sourceID)
    }
    setup.message(object: dataManagerID, opcode: 1) {
        $0.newId(deviceID)
        $0.object(seatID)
    }
    setup.message(object: sourceID, opcode: 0) {
        $0.string("text/plain")
    }
    setup.message(object: sourceID, opcode: 2) {
        $0.uint(1 | 2)
    }
    #expect(client.send(setup))
    client.pump()
    _ = client.drainEvents()

    let surface = try #require(compositor.surface(id: surfaceID))
    let clientKey = try #require(
        surface.resource.flatMap(wl_resource_get_client)
            .map(WlSeat.clientKey))
    _ = seat.pointerEnter(
        surface, surfaceX: 4, surfaceY: 5)
    let serial = seat.pointerButton(
        clientKey: clientKey,
        surface: surface,
        timeMsec: 10,
        button: 0x110,
        state: 1)
    #expect(serial != 0)
    router.flushClients()
    _ = client.drainEvents()

    var start = WireBuilder()
    start.message(object: deviceID, opcode: 0) {
        $0.object(sourceID)
        $0.object(surfaceID)
        $0.object(0)
        $0.uint(serial)
    }
    #expect(client.send(start))
    client.pump()
    #expect(dataDevice.dragActive)

    #expect(dataDevice.dragMotion(
        surfaceID: UInt64(surfaceID),
        x: 12,
        y: 14,
        timeMsec: 11))
    router.flushClients()
    let entered = client.drainEvents()
    let offerEvent = try #require(
        WireMessage.first(
            entered, object: deviceID, opcode: 0))
    let offerID = offerEvent.u32(0)
    #expect(WireMessage.first(
        entered, object: offerID, opcode: 0) != nil)
    #expect(WireMessage.first(
        entered, object: offerID, opcode: 1) != nil)
    #expect(WireMessage.first(
        entered, object: deviceID, opcode: 1) != nil)
    #expect(WireMessage.first(
        entered, object: deviceID, opcode: 3) != nil)

    var accept = WireBuilder()
    accept.message(object: offerID, opcode: 0) {
        $0.uint(serial)
        $0.string("text/plain")
    }
    accept.message(object: offerID, opcode: 4) {
        $0.uint(1 | 2)
        $0.uint(2)
    }
    #expect(client.send(accept))
    client.pump()
    let negotiated = client.drainEvents()
    #expect(WireMessage.first(
        negotiated, object: sourceID, opcode: 0) != nil)
    #expect(WireMessage.first(
        negotiated, object: sourceID, opcode: 5) != nil)
    #expect(WireMessage.first(
        negotiated, object: offerID, opcode: 2) != nil)

    #expect(dataDevice.dropActiveDrag())
    router.flushClients()
    let dropped = client.drainEvents()
    #expect(WireMessage.first(
        dropped, object: deviceID, opcode: 4) != nil)
    #expect(WireMessage.first(
        dropped, object: sourceID, opcode: 3) != nil)

    var finish = WireBuilder()
    finish.message(object: offerID, opcode: 3) { _ in }
    #expect(client.send(finish))
    client.pump()
    let finished = client.drainEvents()
    #expect(WireMessage.first(
        finished, object: sourceID, opcode: 4) != nil)
    #expect(!dataDevice.dragActive)
}

// MARK: - layer-shell

/// A layer surface must reject an out-of-range anchor bitfield with invalid_anchor
/// (value 2 on the layer_surface). Regression guard for the `set_anchor` validation.
@Test func layerShellRejectsInvalidAnchor() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 1920, pixelHeight: 1080,
        refreshMhz: 60000, scale: 1, name: "DP-1", description: "Out")).register(in: router)
    let layerShell = ZwlrLayerShell(); layerShell.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let lsId: UInt32 = 3, compId: UInt32 = 4, outId: UInt32 = 5, surfId: UInt32 = 6, layerId: UInt32 = 7

    var a = WireBuilder()
    try bind(&a, "zwlr_layer_shell_v1", lsId, globals)
    try bind(&a, "wl_compositor", compId, globals)
    try bind(&a, "wl_output", outId, globals)
    a.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
    a.message(object: lsId, opcode: 0) {                        // get_layer_surface(top=2, "panel")
        $0.newId(layerId); $0.object(surfId); $0.object(outId); $0.uint(2); $0.string("panel")
    }
    a.message(object: layerId, opcode: 1) { $0.uint(0x40) }     // set_anchor: bit outside top|bottom|left|right
    client.send(a)
    client.pump()

    let err = try #require(WireError.first(client.drainEvents()), "expected a protocol error")
    #expect(err.objectID == layerId)
    #expect(err.code == 2)  // invalid_anchor
}

/// `set_layer` with an out-of-range layer must raise invalid_layer (value 1), not
/// invalid_anchor. Regression guard for the corrected error code.
@Test func layerShellRejectsInvalidLayer() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 1920, pixelHeight: 1080,
        refreshMhz: 60000, scale: 1, name: "DP-1", description: "Out")).register(in: router)
    ZwlrLayerShell().register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let lsId: UInt32 = 3, compId: UInt32 = 4, outId: UInt32 = 5, surfId: UInt32 = 6, layerId: UInt32 = 7

    var a = WireBuilder()
    try bind(&a, "zwlr_layer_shell_v1", lsId, globals)
    try bind(&a, "wl_compositor", compId, globals)
    try bind(&a, "wl_output", outId, globals)
    a.message(object: compId, opcode: 0) { $0.newId(surfId) }
    a.message(object: lsId, opcode: 0) {
        $0.newId(layerId); $0.object(surfId); $0.object(outId); $0.uint(2); $0.string("panel")
    }
    a.message(object: layerId, opcode: 8) { $0.uint(4) }  // set_layer: 4 is out of range (0…3)
    client.send(a)
    client.pump()

    let err = try #require(WireError.first(client.drainEvents()), "expected a protocol error")
    #expect(err.objectID == layerId)
    #expect(err.code == 1)  // invalid_layer, not 2 (invalid_anchor)
}

/// The initial buffer is not part of the layer-shell construction commit. A client
/// must first receive and acknowledge configure; accepting the buffer early makes
/// the compositor and client disagree about the role's arranged size.
@Test func layerShellRejectsBufferBeforeAckConfigure() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340,
        pixelWidth: 1920, pixelHeight: 1080,
        refreshMhz: 60_000, scale: 1,
        name: "DP-1", description: "Out"
    )).register(in: router)
    ZwlrLayerShell().register(in: router)

    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmID: UInt32 = 3
    let compositorID: UInt32 = 4
    let outputID: UInt32 = 5
    let shellID: UInt32 = 6
    let surfaceID: UInt32 = 7
    let layerID: UInt32 = 8
    let poolID: UInt32 = 9
    let bufferID: UInt32 = 10

    var setup = WireBuilder()
    try bind(&setup, "wl_shm", shmID, globals)
    try bind(&setup, "wl_compositor", compositorID, globals)
    try bind(&setup, "wl_output", outputID, globals)
    try bind(&setup, "zwlr_layer_shell_v1", shellID, globals)
    setup.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    setup.message(object: shellID, opcode: 0) {
        $0.newId(layerID)
        $0.object(surfaceID)
        $0.object(outputID)
        $0.uint(2)
        $0.string("panel")
    }
    setup.message(object: layerID, opcode: 0) {
        $0.uint(4)
        $0.uint(4)
    }
    setup.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(setup))
    client.pump()
    let configured = client.drainEvents()
    #expect(WireMessage.first(
        configured, object: layerID, opcode: 0) != nil)

    var create = WireBuilder()
    let fd = try appendShmBuffer(
        &create,
        shmId: shmID, poolId: poolID, bufId: bufferID,
        width: 4, height: 4, stride: 16, format: 0)
    try client.send(create, fd: fd)
    client.pump()

    var map = WireBuilder()
    map.message(object: surfaceID, opcode: 1) {
        $0.object(bufferID)
        $0.int(0)
        $0.int(0)
    }
    map.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(map))
    client.pump()

    let error = try #require(
        WireError.first(client.drainEvents()))
    #expect(error.objectID == layerID)
    #expect(error.code == 0)
}

// MARK: - foreign-toplevel

/// Decode a zwlr_foreign_toplevel_handle_v1.state event (opcode 4) — a wl_array of
/// u32 state values (byte-length prefixed).
private func stateSet(_ m: WireMessage) -> [UInt32] {
    let byteLen = Int(m.u32(0))
    var out: [UInt32] = []
    var off = 4
    while off + 4 <= 4 + byteLen { out.append(m.u32(off)); off += 4 }
    return out
}

/// The handle `state` array must carry `minimized` (value 1) exactly when the model
/// window is minimized — in both directions. Regression guard for the state that was
/// previously never reported (so taskbars rendered minimized windows as un-minimized),
/// and the reconcile path the unminimize fix drives.
@MainActor @Test func foreignToplevelReportsMinimizedState() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor(); compositor.register(in: router)
    let server = NucleusCompositorServer.shared
    for w in server.windows.windows { _ = server.destroyWindow(id: w.id) }  // isolate the shared model
    defer { for w in server.windows.windows { _ = server.destroyWindow(id: w.id) } }

    let window = server.createWindow(source: .xdg)
    window.managedAppWindow = true
    window.surfaceObjectId = 4242
    window.title = "T"; window.appId = "app"
    window.mapped = true
    window.minimized = true

    let manager = ZwlrForeignToplevelManager(compositor: compositor); manager.register(in: router)
    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let mgrId: UInt32 = 3

    var a = WireBuilder()
    try bind(&a, "zwlr_foreign_toplevel_manager_v1", mgrId, globals)  // bind → replays the window
    client.send(a)
    client.pump()
    let enumerated = client.drainEvents()

    // The manager announces the handle (toplevel event, opcode 0, new_id arg).
    let toplevel = try #require(WireMessage.first(enumerated, object: mgrId, opcode: 0), "no toplevel handle")
    let handleId = toplevel.u32(0)
    // The replayed state array carries minimized.
    let firstState = try #require(
        enumerated.last { $0.objectId == handleId && $0.opcode == 4 }, "no state event")
    #expect(stateSet(firstState).contains(1), "minimized must be reported when the window is minimized")

    // Restore the window: the next reconcile drops minimized from the state array.
    window.minimized = false
    server.drainChanges()
    let afterRestore = client.drainEvents()
    let restoredState = try #require(
        afterRestore.last { $0.objectId == handleId && $0.opcode == 4 }, "no state event after restore")
    #expect(!stateSet(restoredState).contains(1), "minimized must clear when the window is restored")
}

// MARK: - screencopy

private final class ScreencopyStub: ScreencopyDelegate {
    func screencopyConfiguration(
        output: WlOutput?, region: WlRect?
    ) -> ScreencopyConfiguration? {
        // Advertise a 64×48 XRGB8888 frame at stride 256.
        ScreencopyConfiguration(
            params: ScreencopyParams(
                shmFormat: 1, width: 64, height: 48,
                stride: 256, drmFourcc: 0x3432_5258),
            sourceRegion: nil)
    }
    func screencopyRequestFrame(output: WlOutput?) {}
    func screencopyCapture(
        output: WlOutput?,
        configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>,
        withDamage: Bool,
        preferRegionReadback: Bool,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64? {
        completion(ScreencopyResult(
            ok: false, tvSecHi: 0, tvSecLo: 0,
            tvNsec: 0, flags: 0))
        return 1
    }
    func screencopyCancelCapture(_: UInt64) {}
}

private final class SuccessfulScreencopyStub: ScreencopyDelegate {
    var requestedOutputIDs: [UInt64] = []
    var captureCount = 0
    var cancelledRequestIDs: [UInt64] = []
    var pendingCompletion: (@MainActor (ScreencopyResult) -> Void)?

    func screencopyConfiguration(
        output: WlOutput?, region: WlRect?
    ) -> ScreencopyConfiguration? {
        ScreencopyConfiguration(
            params: ScreencopyParams(
                shmFormat: 1, width: 4, height: 4,
                stride: 16, drmFourcc: testDrmFormatXrgb8888),
            sourceRegion: nil)
    }

    func screencopyRequestFrame(output: WlOutput?) {
        requestedOutputIDs.append(output?.outputId ?? 0)
    }

    func screencopyCapture(
        output: WlOutput?,
        configuration: ScreencopyConfiguration,
        overlayCursor: Bool,
        buffer: UnsafeMutablePointer<wl_resource>,
        withDamage: Bool,
        preferRegionReadback: Bool,
        completion: @escaping @MainActor (ScreencopyResult) -> Void
    ) -> UInt64? {
        captureCount += 1
        pendingCompletion = completion
        return 88
    }
    func screencopyCancelCapture(_ requestID: UInt64) {
        cancelledRequestIDs.append(requestID)
        pendingCompletion = nil
    }

    func complete() {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(ScreencopyResult(
            ok: true, tvSecHi: 0, tvSecLo: 73,
            tvNsec: 19, flags: 0))
    }
}

@Test func screencopyLogicalRegionsClipBeforePixelProjection() throws {
    let clipped = try #require(RouterRenderDriver.projectCaptureAxis(
        origin: -10,
        length: 30,
        logicalExtent: 100,
        pixelExtent: 200))
    #expect(clipped.origin == 0)
    #expect(clipped.length == 40)

    let fractional = try #require(RouterRenderDriver.projectCaptureAxis(
        origin: 1,
        length: 1,
        logicalExtent: 3,
        pixelExtent: 5))
    #expect(fractional.origin == 1)
    #expect(fractional.length == 3)

    #expect(RouterRenderDriver.projectCaptureAxis(
        origin: 100,
        length: 1,
        logicalExtent: 100,
        pixelExtent: 200) == nil)
}

/// A copy request must wait for a newly accepted submission on its exact output.
/// Completing it in the request handler reads an arbitrary older accumulator.
@Test func screencopyCompletesAgainstRequestedOutputSubmission() throws {
    let router = try #require(NucleusWaylandRouter())
    let outputID: UInt64 = 701
    let output = WlOutput(info: OutputInfo(
        outputId: outputID,
        physicalWidthMm: 600, physicalHeightMm: 340,
        pixelWidth: 4, pixelHeight: 4,
        refreshMhz: 60_000, scale: 1,
        name: "DP-1", description: "Capture output"))
    #expect(output.register(in: router))
    let stub = SuccessfulScreencopyStub()
    let manager = ScreencopyManager()
    manager.delegate = stub
    manager.register(in: router)

    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmID: UInt32 = 3
    let outputObjectID: UInt32 = 4
    let managerID: UInt32 = 5
    let poolID: UInt32 = 6
    let bufferID: UInt32 = 7
    let frameID: UInt32 = 8

    var setup = WireBuilder()
    try bind(&setup, "wl_shm", shmID, globals)
    try bind(
        &setup, "wl_output", outputObjectID, globals)
    try bind(
        &setup, "zwlr_screencopy_manager_v1",
        managerID, globals)
    #expect(client.send(setup))
    client.pump()
    _ = client.drainEvents()

    var shm = WireBuilder()
    let fd = try appendShmBuffer(
        &shm, shmId: shmID, poolId: poolID,
        bufId: bufferID, width: 4, height: 4,
        stride: 16, format: 1)
    try client.send(shm, fd: fd)
    client.pump()
    _ = client.drainEvents()

    var capture = WireBuilder()
    capture.message(object: managerID, opcode: 0) {
        $0.newId(frameID)
        $0.int(0)
        $0.object(outputObjectID)
    }
    capture.message(object: frameID, opcode: 0) {
        $0.object(bufferID)
    }
    #expect(client.send(capture))
    client.pump()

    let beforeSubmission = client.drainEvents()
    #expect(
        WireMessage.first(
            beforeSubmission, object: frameID,
            opcode: 2) == nil)
    #expect(stub.requestedOutputIDs == [outputID])
    #expect(stub.captureCount == 0)

    manager.outputSubmitted(outputID)
    client.pump()
    #expect(client.drainEvents().isEmpty)
    #expect(stub.captureCount == 1)

    stub.complete()
    client.pump()
    let afterSubmission = client.drainEvents()
    let ready = try #require(
        WireMessage.first(
            afterSubmission, object: frameID, opcode: 2))
    #expect(ready.u32(0) == 0)
    #expect(ready.u32(4) == 73)
    #expect(ready.u32(8) == 19)
    #expect(stub.pendingCompletion == nil)

    // Destroying a frame after its GPU capture begins must cancel that exact
    // request and discard its completion before the retained wl_buffer dies.
    let cancelledFrameID: UInt32 = 9
    var cancelledCapture = WireBuilder()
    cancelledCapture.message(object: managerID, opcode: 0) {
        $0.newId(cancelledFrameID)
        $0.int(0)
        $0.object(outputObjectID)
    }
    cancelledCapture.message(object: cancelledFrameID, opcode: 0) {
        $0.object(bufferID)
    }
    #expect(client.send(cancelledCapture))
    client.pump()
    _ = client.drainEvents()
    manager.outputSubmitted(outputID)
    #expect(stub.captureCount == 2)
    #expect(stub.pendingCompletion != nil)

    var destroyFrame = WireBuilder()
    destroyFrame.message(object: cancelledFrameID, opcode: 1) { _ in }
    #expect(client.send(destroyFrame))
    client.pump()
    #expect(stub.cancelledRequestIDs == [88])
    #expect(stub.pendingCompletion == nil)
}

/// `copy` with a buffer whose format/size/stride doesn't match the advertised params
/// must be rejected with invalid_buffer (value 1) before any readback. Regression
/// guard for the validation that pre-empts an out-of-bounds copy.
@Test func screencopyRejectsMismatchedBuffer() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 64, pixelHeight: 48,
        refreshMhz: 60000, scale: 1, name: "DP-1", description: "Out")).register(in: router)
    let stub = ScreencopyStub()
    let mgr = ScreencopyManager(); mgr.delegate = stub; mgr.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmId: UInt32 = 3, outId: UInt32 = 4, scId: UInt32 = 5
    let poolId: UInt32 = 6, bufId: UInt32 = 7, frameId: UInt32 = 8

    var bindings = WireBuilder()
    try bind(&bindings, "wl_shm", shmId, globals)
    try bind(&bindings, "wl_output", outId, globals)
    try bind(&bindings, "zwlr_screencopy_manager_v1", scId, globals)
    #expect(client.send(bindings))
    client.pump()

    // A 4×4/stride-16/ARGB buffer — mismatches the advertised 64×48/256/XRGB frame.
    var shm = WireBuilder()
    let fd = try appendShmBuffer(&shm, shmId: shmId, poolId: poolId, bufId: bufId,
        width: 4, height: 4, stride: 16, format: 0)
    try client.send(shm, fd: fd)
    client.pump()

    var capture = WireBuilder()
    capture.message(object: scId, opcode: 0) {
        $0.newId(frameId); $0.int(0); $0.object(outId)
    }
    #expect(client.send(capture))
    client.pump()
    // The frame advertises its buffer (opcode 0); the client then copies.
    #expect(WireMessage.first(client.drainEvents(), object: frameId, opcode: 0) != nil, "no buffer event")

    var b = WireBuilder()
    b.message(object: frameId, opcode: 0) { $0.object(bufId) }  // copy(buffer)
    client.send(b)
    client.pump()
    let err = try #require(WireError.first(client.drainEvents()), "expected invalid_buffer")
    #expect(err.objectID == frameId)
    #expect(err.code == 1)  // invalid_buffer
}

// MARK: - buffer helper

/// A memfd-backed wl_shm pool with one buffer, appended to `b`. Returns the fd to
/// pass to `client.send(_, fd:)` (SCM_RIGHTS). The owned wrapper closes it after send.
/// `format` 0 = ARGB8888, 1 = XRGB8888.
private func appendShmBuffer(
    _ b: inout WireBuilder, shmId: UInt32, poolId: UInt32, bufId: UInt32,
    width: Int32, height: Int32, stride: Int32, format: UInt32
) throws -> OwnedTestFD {
    let (size, overflow) = stride.multipliedReportingOverflow(by: height)
    guard !overflow, size > 0 else { throw WaylandWireError.sizeOverflow }
    let fd = memfd_create("nucleus-wayland-conformance", 0)
    guard fd >= 0 else { throw WaylandWireError.systemCall("memfd_create", errno) }
    let owned = OwnedTestFD(fd)
    guard ftruncate(fd, off_t(size)) == 0 else {
        throw WaylandWireError.systemCall("ftruncate", errno)
    }
    b.message(object: shmId, opcode: 0) { $0.newId(poolId); $0.int(size) }  // create_pool (fd ancillary)
    b.message(object: poolId, opcode: 0) {                                   // create_buffer
        $0.newId(bufId); $0.int(0); $0.int(width); $0.int(height); $0.int(stride); $0.uint(format)
    }
    return owned
}

private final class RecordingSurfaceScene: SurfaceSceneDelegate {
    var commits: [SurfaceCommit] = []
    var destroyedSurfaceIDs: [UInt32] = []

    func surfaceCommitted(_ commit: SurfaceCommit) {
        commits.append(commit)
    }

    func surfaceDestroyed(surfaceID: UInt32, iosurfaceID: UInt32) {
        destroyedSurfaceIDs.append(surfaceID)
    }
}

/// State-only commits retain the last attached buffer's geometry but must not look
/// like a fresh buffer attach to the scene importer. Re-importing here turns every
/// frame-callback, damage-only, or viewport-only commit into an unnecessary GPU
/// upload and can dereference a wl_buffer the client has already destroyed.
@Test func stateOnlySurfaceCommitPreservesBufferWithoutReattaching() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    let scene = RecordingSurfaceScene()
    compositor.sceneDelegate = scene
    compositor.register(in: router)

    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmID: UInt32 = 3
    let compositorID: UInt32 = 4
    let poolID: UInt32 = 5
    let bufferID: UInt32 = 6
    let surfaceID: UInt32 = 7

    var setup = WireBuilder()
    try bind(&setup, "wl_shm", shmID, globals)
    try bind(
        &setup, "wl_compositor", compositorID, globals)
    let fd = try appendShmBuffer(
        &setup, shmId: shmID, poolId: poolID,
        bufId: bufferID, width: 4, height: 3,
        stride: 16, format: 0)
    setup.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    try client.send(setup, fd: fd)
    client.pump()
    _ = client.drainEvents()

    var commits = WireBuilder()
    commits.message(object: surfaceID, opcode: 1) {
        $0.object(bufferID)
        $0.int(0)
        $0.int(0)
    }
    commits.message(object: surfaceID, opcode: 6) { _ in }
    commits.message(object: surfaceID, opcode: 2) {
        $0.int(0)
        $0.int(0)
        $0.int(1)
        $0.int(1)
    }
    commits.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(commits))
    client.pump()

    #expect(scene.commits.count == 2)
    let first = try #require(scene.commits.first)
    let second = try #require(scene.commits.last)
    #expect(first.bufferAttached)
    #expect(first.bufferPixelSize.width == 4)
    #expect(first.bufferPixelSize.height == 3)
    #expect(!second.bufferAttached)
    #expect(second.bufferPixelSize == first.bufferPixelSize)
    #expect(second.bufferGeneration == first.bufferGeneration)
    #expect(second.bufferResourceBits == first.bufferResourceBits)
    #expect(second.surfaceDamage == [
        WlRect(x: 0, y: 0, width: 1, height: 1)
    ])
}

private final class PreferredScaleProbe: PreferredScaleSink {
    var lastScale120: UInt32?
    func sendPreferredScale(_ scale120: UInt32) { lastScale120 = scale120 }
}

/// Fractional scaling has two distinct protocol representations: wl_output.scale
/// is integer-only, while xdg-output geometry and wp_fractional_scale must retain
/// the compositor's exact scale. Rounding 1.5 up to 2 made full-width layer-shell
/// surfaces cover only part of the physical output.
@Test func fractionalOutputPreservesLogicalGeometryAndPreferredScale() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)
    let output = WlOutput(info: OutputInfo(
        outputId: 822,
        physicalWidthMm: 600, physicalHeightMm: 340,
        pixelWidth: 3840, pixelHeight: 2160, refreshMhz: 120_000,
        scale: 2, name: "DP-1", description: "Fractional output",
        logicalWidth: 2560, logicalHeight: 1440, fractionalScale: 1.5))
    compositor.addOutput(output)

    #expect(output.logicalRect.width == 2560)
    #expect(output.logicalRect.height == 1440)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compId: UInt32 = 3, surfaceId: UInt32 = 4
    var requests = WireBuilder()
    try bind(&requests, "wl_compositor", compId, globals)
    requests.message(object: compId, opcode: 0) { $0.newId(surfaceId) }
    #expect(client.send(requests))
    client.pump()

    let surface = try #require(compositor.surface(id: surfaceId))
    let probe = PreferredScaleProbe()
    surface.fractionalScaleSink = probe
    surface.updateEnteredOutputs([822])
    #expect(probe.lastScale120 == 180)
}

@Test func outputUpdateRefreshesBindingsAndRemovalWithdrawsGlobal() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)
    let xdgOutputManager = XdgOutputManager()
    xdgOutputManager.register(in: router)
    let output = WlOutput(info: OutputInfo(
        outputId: 701,
        x: 0, y: 0,
        physicalWidthMm: 500,
        physicalHeightMm: 300,
        pixelWidth: 1_920,
        pixelHeight: 1_080,
        refreshMhz: 60_000,
        scale: 1,
        name: "DP-1",
        description: "Initial",
        logicalWidth: 1_920,
        logicalHeight: 1_080,
        fractionalScale: 1))
    #expect(output.register(in: router))
    compositor.addOutput(output)

    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let outputGlobal = try #require(
        globals.first { $0.interface == "wl_output" })
    let outputID: UInt32 = 3
    let managerID: UInt32 = 4
    let xdgOutputID: UInt32 = 5
    var bindRequest = WireBuilder()
    try bind(
        &bindRequest, "wl_output", outputID, globals)
    try bind(
        &bindRequest, "zxdg_output_manager_v1",
        managerID, globals)
    bindRequest.message(object: managerID, opcode: 1) {
        $0.newId(xdgOutputID)
        $0.object(outputID)
    }
    #expect(client.send(bindRequest))
    client.pump()
    _ = client.drainEvents()

    output.apply(OutputInfo(
        outputId: 701,
        x: 1_920, y: 40,
        physicalWidthMm: 600,
        physicalHeightMm: 340,
        pixelWidth: 3_840,
        pixelHeight: 2_160,
        refreshMhz: 59_940,
        scale: 2,
        name: "DP-1",
        description: "Updated",
        logicalWidth: 2_560,
        logicalHeight: 1_440,
        fractionalScale: 1.5))
    router.flushClients()
    let updated = client.drainEvents()
    let geometry = try #require(
        WireMessage.first(
            updated, object: outputID, opcode: 0))
    #expect(Int32(bitPattern: geometry.u32(0)) == 1_920)
    #expect(Int32(bitPattern: geometry.u32(4)) == 40)
    let mode = try #require(
        WireMessage.first(
            updated, object: outputID, opcode: 1))
    #expect(Int32(bitPattern: mode.u32(4)) == 3_840)
    #expect(Int32(bitPattern: mode.u32(8)) == 2_160)
    #expect(Int32(bitPattern: mode.u32(12)) == 59_940)
    let scale = try #require(
        WireMessage.first(
            updated, object: outputID, opcode: 3))
    #expect(Int32(bitPattern: scale.u32(0)) == 2)
    let logicalPosition = try #require(
        WireMessage.first(
            updated, object: xdgOutputID, opcode: 0))
    #expect(
        Int32(bitPattern: logicalPosition.u32(0))
            == 1_920)
    #expect(
        Int32(bitPattern: logicalPosition.u32(4))
            == 40)
    let logicalSize = try #require(
        WireMessage.first(
            updated, object: xdgOutputID, opcode: 1))
    #expect(
        Int32(bitPattern: logicalSize.u32(0))
            == 2_560)
    #expect(
        Int32(bitPattern: logicalSize.u32(4))
            == 1_440)

    #expect(compositor.prepareOutputRemoval(id: 701))
    router.flushClients()
    #expect(
        WireMessage.first(
            client.drainEvents(), object: 2,
            opcode: 1) == nil,
        "prepare must retain the global for window migration")
    _ = compositor.finishOutputRemoval(id: 701)
    router.flushClients()
    let removed = try #require(
        WireMessage.first(
            client.drainEvents(), object: 2, opcode: 1))
    #expect(removed.u32(0) == outputGlobal.name)
}

/// A client may destroy a wl_buffer after committing it. Replacing that content
/// later must not send wl_buffer.release through the now-freed wl_resource.
/// Regression guard for the profile-session SIGSEGV in wl_resource_post_event.
@Test func replacingDestroyedCurrentBufferDoesNotUseFreedResource() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmId: UInt32 = 3, compId: UInt32 = 4, surfId: UInt32 = 5
    let poolA: UInt32 = 6, bufA: UInt32 = 7, poolB: UInt32 = 8, bufB: UInt32 = 9

    var bindings = WireBuilder()
    try bind(&bindings, "wl_shm", shmId, globals)
    try bind(&bindings, "wl_compositor", compId, globals)
    bindings.message(object: compId, opcode: 0) { $0.newId(surfId) }
    #expect(client.send(bindings))
    client.pump()
    _ = client.drainEvents()

    var createA = WireBuilder()
    let fdA = try appendShmBuffer(
        &createA, shmId: shmId, poolId: poolA, bufId: bufA,
        width: 4, height: 4, stride: 16, format: 0)
    try client.send(createA, fd: fdA)

    var createB = WireBuilder()
    let fdB = try appendShmBuffer(
        &createB, shmId: shmId, poolId: poolB, bufId: bufB,
        width: 4, height: 4, stride: 16, format: 0)
    try client.send(createB, fd: fdB)
    client.pump()

    var firstCommit = WireBuilder()
    firstCommit.message(object: surfId, opcode: 1) {
        $0.object(bufA); $0.int(0); $0.int(0)
    }
    firstCommit.message(object: surfId, opcode: 6) { _ in }
    #expect(client.send(firstCommit))
    client.pump()

    // Destroy A's wire object, then replace its still-current content with B.
    // The old implementation retained bufA's raw wl_resource pointer here and
    // crashed in wl_buffer_send_release while dispatching the second commit.
    var replace = WireBuilder()
    replace.message(object: bufA, opcode: 0) { _ in }  // wl_buffer.destroy
    replace.message(object: surfId, opcode: 1) {
        $0.object(bufB); $0.int(0); $0.int(0)
    }
    replace.message(object: surfId, opcode: 6) { _ in }
    #expect(client.send(replace))
    client.pump()

    let surface = try #require(compositor.surface(id: surfId))
    #expect(surface.hasCurrentBuffer)
    #expect(surface.currentBuffer.map { wl_resource_get_id($0) } == bufB)
}

/// A buffer rejected before renderer ownership is immediately reusable, but its
/// later replacement must not emit a second wl_buffer.release. This exercises the
/// exact-once failure transition independently of any hardware import backend.
@Test func immediatelyReusableBufferIsReleasedExactlyOnce() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmID: UInt32 = 3, compositorID: UInt32 = 4, surfaceID: UInt32 = 5
    let poolA: UInt32 = 6, bufferA: UInt32 = 7
    let poolB: UInt32 = 8, bufferB: UInt32 = 9

    var setup = WireBuilder()
    try bind(&setup, "wl_shm", shmID, globals)
    try bind(&setup, "wl_compositor", compositorID, globals)
    setup.message(object: compositorID, opcode: 0) { $0.newId(surfaceID) }
    #expect(client.send(setup))
    client.pump()
    _ = client.drainEvents()

    var createA = WireBuilder()
    let fdA = try appendShmBuffer(
        &createA, shmId: shmID, poolId: poolA, bufId: bufferA,
        width: 4, height: 4, stride: 16, format: 0)
    try client.send(createA, fd: fdA)
    var createB = WireBuilder()
    let fdB = try appendShmBuffer(
        &createB, shmId: shmID, poolId: poolB, bufId: bufferB,
        width: 4, height: 4, stride: 16, format: 0)
    try client.send(createB, fd: fdB)
    client.pump()
    _ = client.drainEvents()

    var attachA = WireBuilder()
    attachA.message(object: surfaceID, opcode: 1) {
        $0.object(bufferA); $0.int(0); $0.int(0)
    }
    attachA.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(attachA))
    client.pump()
    _ = client.drainEvents()

    let surface = try #require(compositor.surface(id: surfaceID))
    surface.releaseCurrentBufferImmediately()
    surface.releaseCurrentBufferImmediately()
    router.flushClients()
    let failedEvents = client.drainEvents()
    #expect(failedEvents.filter { $0.objectId == bufferA && $0.opcode == 0 }.count == 1)

    var attachB = WireBuilder()
    attachB.message(object: surfaceID, opcode: 1) {
        $0.object(bufferB); $0.int(0); $0.int(0)
    }
    attachB.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(attachB))
    client.pump()
    #expect(WireMessage.first(client.drainEvents(), object: bufferA, opcode: 0) == nil)
}

@Test func importedDmabufReleaseWaitsForRendererRetirement() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)
    let dmabuf = ZwpLinuxDmabuf()
    let dmabufDelegate = AcceptingDmabufDelegate()
    dmabuf.delegate = dmabufDelegate
    dmabuf.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compID: UInt32 = 3, dmaID: UInt32 = 4, surfaceID: UInt32 = 5
    let paramsA: UInt32 = 6, bufferA: UInt32 = 7
    let paramsB: UInt32 = 8, bufferB: UInt32 = 9
    var setup = WireBuilder()
    try bind(&setup, "wl_compositor", compID, globals)
    try bind(&setup, "zwp_linux_dmabuf_v1", dmaID, globals)
    setup.message(object: compID, opcode: 0) { $0.newId(surfaceID) }
    #expect(client.send(setup))
    client.pump()
    _ = client.drainEvents()

    func createBuffer(paramsID: UInt32, bufferID: UInt32) throws {
        let fd = memfd_create("nucleus-retirement-test", 0)
        try #require(fd >= 0)
        let ownedFD = OwnedTestFD(fd)
        var request = WireBuilder()
        request.message(object: dmaID, opcode: 1) { $0.newId(paramsID) }
        request.message(object: paramsID, opcode: 1) {
            $0.uint(0); $0.uint(0); $0.uint(64); $0.uint(0); $0.uint(0)
        }
        request.message(object: paramsID, opcode: 3) {
            $0.newId(bufferID); $0.int(4); $0.int(4)
            $0.uint(testDrmFormatXrgb8888); $0.uint(0)
        }
        try client.send(request, fd: ownedFD)
        client.pump()
        _ = client.drainEvents()
    }
    try createBuffer(paramsID: paramsA, bufferID: bufferA)
    try createBuffer(paramsID: paramsB, bufferID: bufferB)

    var first = WireBuilder()
    first.message(object: surfaceID, opcode: 1) {
        $0.object(bufferA); $0.int(0); $0.int(0)
    }
    first.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(first))
    client.pump()
    let surface = try #require(compositor.surface(id: surfaceID))
    surface.renderIosurfaceId = 77
    _ = client.drainEvents()

    var replace = WireBuilder()
    replace.message(object: surfaceID, opcode: 1) {
        $0.object(bufferB); $0.int(0); $0.int(0)
    }
    replace.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(replace))
    client.pump()
    #expect(WireMessage.first(client.drainEvents(), object: bufferA, opcode: 0) == nil)

    compositor.retireBuffer(iosurfaceID: 77)
    router.flushClients()
    #expect(WireMessage.first(client.drainEvents(), object: bufferA, opcode: 0) != nil)
}

/// A wl_surface with a committed buffer cannot become a layer surface:
/// already_constructed (value 2 on the zwlr_layer_shell_v1). Regression guard.
@Test func layerShellRejectsBufferedSurface() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 1920, pixelHeight: 1080,
        refreshMhz: 60000, scale: 1, name: "DP-1", description: "Out")).register(in: router)
    ZwlrLayerShell().register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmId: UInt32 = 3, compId: UInt32 = 4, outId: UInt32 = 5, lsId: UInt32 = 6
    let poolId: UInt32 = 7, bufId: UInt32 = 8, surfId: UInt32 = 9, layerId: UInt32 = 10

    var a = WireBuilder()
    try bind(&a, "wl_shm", shmId, globals)
    try bind(&a, "wl_compositor", compId, globals)
    try bind(&a, "wl_output", outId, globals)
    try bind(&a, "zwlr_layer_shell_v1", lsId, globals)
    let fd = try appendShmBuffer(&a, shmId: shmId, poolId: poolId, bufId: bufId,
        width: 4, height: 4, stride: 16, format: 0)
    a.message(object: compId, opcode: 0) { $0.newId(surfId) }         // create_surface
    a.message(object: surfId, opcode: 1) { $0.object(bufId); $0.int(0); $0.int(0) }  // attach
    a.message(object: surfId, opcode: 6) { _ in }                     // commit → surface has a buffer
    try client.send(a, fd: fd)
    client.pump()
    _ = client.drainEvents()

    // Now try to make it a layer surface — must be rejected.
    var b = WireBuilder()
    b.message(object: lsId, opcode: 0) {
        $0.newId(layerId); $0.object(surfId); $0.object(outId); $0.uint(2); $0.string("panel")
    }
    client.send(b)
    client.pump()
    let err = try #require(WireError.first(client.drainEvents()), "expected already_constructed")
    #expect(err.objectID == lsId)
    #expect(err.code == 2)  // already_constructed
}

/// The foreign-toplevel minimize *routing* fix: `unset_minimized` (and activate)
/// must restore a minimized window. Exercises `RouterWindowDriver.foreignSetMinimized`
/// directly — before the fix, the `false` branch was a no-op and `window.minimized`
/// had no path back, so this would leave the window stranded.
@MainActor @Test func foreignToplevelUnminimizeRestoresWindow() throws {
    let compositor = WlCompositor()
    let driver = RouterWindowDriver(
        seatDriver: RouterSeatDriver(seat: WlSeat(), compositor: compositor), compositor: compositor)
    let server = NucleusCompositorServer.shared
    for w in server.windows.windows { _ = server.destroyWindow(id: w.id) }
    defer { for w in server.windows.windows { _ = server.destroyWindow(id: w.id) } }

    let window = server.createWindow(source: .xdg)
    window.managedAppWindow = true
    window.surfaceObjectId = 7777
    window.mapped = true

    driver.foreignSetMinimized(windowID: window.id, true)
    #expect(window.minimized, "set_minimized should hide the window")
    driver.foreignSetMinimized(windowID: window.id, false)
    #expect(!window.minimized, "unset_minimized must restore the window (was a permanent dead-end)")
}

// MARK: - session-lock

private final class LockGateStub: SessionLockDelegate {
    var began = false
    func sessionLockBegin() -> Bool { began = true; return true }
    func sessionLockEnd() {}
    func sessionLockSurfaceMapped(_ surface: WlSurface, output: WlOutput?) {}
}

/// A denied second locker is inert: it receives `finished` and any further
/// `get_lock_surface` is ignored (no configure), so it cannot map a lock surface
/// behind the granted lock. The granted first lock still configures normally.
@Test func sessionLockSecondLockerIsInert() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor(); compositor.register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 64, pixelHeight: 48,
        refreshMhz: 60000, scale: 1, name: "LOCK-1", description: "Lock")).register(in: router)
    let gate = LockGateStub()
    let lockMgr = SessionLockManager(); lockMgr.delegate = gate; lockMgr.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compId: UInt32 = 3, outId: UInt32 = 4, mgrId: UInt32 = 5
    let lock1: UInt32 = 6, lock2: UInt32 = 7
    let surf1: UInt32 = 8, surf2: UInt32 = 9, ls1: UInt32 = 10, ls2: UInt32 = 11

    var a = WireBuilder()
    try bind(&a, "wl_compositor", compId, globals)
    try bind(&a, "wl_output", outId, globals)
    try bind(&a, "ext_session_lock_manager_v1", mgrId, globals)
    a.message(object: mgrId, opcode: 1) { $0.newId(lock1) }  // lock (granted)
    a.message(object: mgrId, opcode: 1) { $0.newId(lock2) }  // lock (denied → finished + inert)
    a.message(object: compId, opcode: 0) { $0.newId(surf1) }
    a.message(object: compId, opcode: 0) { $0.newId(surf2) }
    // get_lock_surface(id, surface, output) on each lock.
    a.message(object: lock1, opcode: 1) { $0.newId(ls1); $0.object(surf1); $0.object(outId) }
    a.message(object: lock2, opcode: 1) { $0.newId(ls2); $0.object(surf2); $0.object(outId) }
    client.send(a)
    client.pump()
    let events = client.drainEvents()

    #expect(gate.began)
    // lock2 was denied.
    #expect(WireMessage.first(events, object: lock2, opcode: 1) != nil, "lock2 should be finished")
    // The granted lock's surface is configured (ext_session_lock_surface_v1.configure = op 0).
    #expect(WireMessage.first(events, object: ls1, opcode: 0) != nil, "granted lock surface must configure")
    // The inert lock's get_lock_surface is ignored — no configure on ls2.
    #expect(WireMessage.first(events, object: ls2, opcode: 0) == nil, "inert lock must not configure a surface")
}

/// A lock surface that commits a buffer not matching its configured size must be
/// rejected with dimensions_mismatch (value 2). Regression guard.
@Test func sessionLockRejectsMismatchedBuffer() throws {
    let router = try #require(NucleusWaylandRouter())
    WlCompositor().register(in: router)
    WlOutput(info: OutputInfo(
        physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 64, pixelHeight: 48,
        refreshMhz: 60000, scale: 1, name: "LOCK-1", description: "Lock")).register(in: router)
    let gate = LockGateStub()
    let lockMgr = SessionLockManager(); lockMgr.delegate = gate; lockMgr.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let shmId: UInt32 = 3, compId: UInt32 = 4, outId: UInt32 = 5, mgrId: UInt32 = 6
    let lock1: UInt32 = 7, poolId: UInt32 = 8, bufId: UInt32 = 9, surfId: UInt32 = 10, lsurf: UInt32 = 11

    var a = WireBuilder()
    try bind(&a, "wl_shm", shmId, globals)
    try bind(&a, "wl_compositor", compId, globals)
    try bind(&a, "wl_output", outId, globals)
    try bind(&a, "ext_session_lock_manager_v1", mgrId, globals)
    a.message(object: mgrId, opcode: 1) { $0.newId(lock1) }  // lock (granted)
    // A 4×4 buffer — the output (and thus the configure) is 64×48, so it mismatches.
    let fd = try appendShmBuffer(&a, shmId: shmId, poolId: poolId, bufId: bufId,
        width: 4, height: 4, stride: 16, format: 0)
    a.message(object: compId, opcode: 0) { $0.newId(surfId) }
    a.message(object: lock1, opcode: 1) { $0.newId(lsurf); $0.object(surfId); $0.object(outId) }  // get_lock_surface
    try client.send(a, fd: fd)
    client.pump()
    let configured = client.drainEvents()

    let cfg = try #require(WireMessage.first(configured, object: lsurf, opcode: 0), "no configure")
    let serial = cfg.u32(0)
    #expect(cfg.u32(4) == 64 && cfg.u32(8) == 48)  // configured to the output

    var b = WireBuilder()
    b.message(object: lsurf, opcode: 1) { $0.uint(serial) }  // ack_configure
    b.message(object: surfId, opcode: 1) { $0.object(bufId); $0.int(0); $0.int(0) }  // attach 4×4
    b.message(object: surfId, opcode: 6) { _ in }            // commit → mismatch
    client.send(b)
    client.pump()
    let err = try #require(WireError.first(client.drainEvents()), "expected dimensions_mismatch")
    #expect(err.objectID == lsurf)
    #expect(err.code == 2)  // dimensions_mismatch
}

// MARK: - present tick (M0: the live driver for wl_surface.frame + wp_presentation_feedback)

/// An accepted frame freezes the exact sampled surface commit, and only the
/// matching page flip completes its callback and presentation feedback.
@MainActor @Test func presentTickDeliversFrameCallbackAndFeedback() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)
    router.compositor = compositor  // wired by WaylandRouterRuntime live; the present tick routes through it
    WpPresentation().register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    let compId: UInt32 = 3, presId: UInt32 = 4, surfId: UInt32 = 5, cbId: UInt32 = 6, fbId: UInt32 = 7

    var a = WireBuilder()
    try bind(&a, "wl_compositor", compId, globals)
    try bind(&a, "wp_presentation", presId, globals)
    a.message(object: compId, opcode: 0) { $0.newId(surfId) }                  // create_surface
    a.message(object: surfId, opcode: 3) { $0.newId(cbId) }                    // wl_surface.frame(callback)
    a.message(object: presId, opcode: 1) { $0.object(surfId); $0.newId(fbId) }  // wp_presentation.feedback
    a.message(object: surfId, opcode: 6) { _ in }                             // commit (latches both)
    client.send(a)
    client.pump()
    _ = client.drainEvents()  // discard bind/create acks

    let surface = try #require(compositor.surface(id: surfId))
    surface.renderIosurfaceId = 99
    surface.renderIosurfaceId = 100
    compositor.submitFrame(
        outputID: 1, outputGeneration: 2, submissionID: 2,
        targetPresentationNs: 6_000_000_123,
        sampledIOSurfaceIDs: [99])
    compositor.presentSubmittedFrame(
        outputID: 1, outputGeneration: 2, submissionID: 2,
        timestampNs: 6_000_000_123,
        refreshNs: 16_666_666, sequence: 41, flags: 0xf)
    #expect(client.drainEvents().isEmpty)

    compositor.submitFrame(
        outputID: 1, outputGeneration: 2, submissionID: 3,
        targetPresentationNs: 7_000_000_123,
        sampledIOSurfaceIDs: [100])
    compositor.presentSubmittedFrame(
        outputID: 1, outputGeneration: 2, submissionID: 3,
        timestampNs: 7_000_000_123,
        refreshNs: 16_666_666, sequence: 42, flags: 0xf)
    let events = client.drainEvents()

    // wl_surface.frame → wl_callback.done on the callback id.
    #expect(WireMessage.first(events, object: cbId, opcode: 0) != nil)
    // wp_presentation_feedback.presented with the 64-bit timestamp/seq split into hi/lo.
    let p = try #require(WireMessage.first(events, object: fbId, opcode: 1), "no presented")
    #expect(p.u32(0) == 0)             // tv_sec_hi
    #expect(p.u32(4) == 7)             // tv_sec_lo  (7_000_000_123 ns → 7 s)
    #expect(p.u32(8) == 123)           // tv_nsec
    #expect(p.u32(12) == 16_666_666)   // refresh
    #expect(p.u32(16) == 0)            // seq_hi
    #expect(p.u32(20) == 42)           // seq_lo
    #expect(p.u32(24) == 0xf)          // flags
}

@MainActor @Test func presentationFeedbackWaitsForEverySampledOutput() throws {
    let router = try #require(NucleusWaylandRouter())
    let compositor = WlCompositor()
    compositor.register(in: router)
    router.compositor = compositor
    WpPresentation().register(in: router)
    let first = WlOutput(info: OutputInfo(
        outputId: 11,
        physicalWidthMm: 500,
        physicalHeightMm: 300,
        pixelWidth: 1_920,
        pixelHeight: 1_080,
        refreshMhz: 60_000,
        scale: 1,
        name: "A",
        description: "A"))
    let second = WlOutput(info: OutputInfo(
        outputId: 22,
        physicalWidthMm: 500,
        physicalHeightMm: 300,
        pixelWidth: 1_920,
        pixelHeight: 1_080,
        refreshMhz: 60_000,
        scale: 1,
        name: "B",
        description: "B"))
    #expect(first.register(in: router))
    #expect(second.register(in: router))
    compositor.addOutput(first)
    compositor.addOutput(second)

    let client = try #require(
        WaylandTestClient(display: router.display))
    let globals = client.globals()
    let outputGlobals = globals.filter {
        $0.interface == "wl_output"
    }
    #expect(outputGlobals.count == 2)
    let compositorID: UInt32 = 3
    let presentationID: UInt32 = 4
    let outputAID: UInt32 = 5
    let outputBID: UInt32 = 6
    let surfaceID: UInt32 = 7
    let feedbackID: UInt32 = 8
    var setup = WireBuilder()
    try bind(
        &setup, "wl_compositor", compositorID, globals)
    try bind(
        &setup, "wp_presentation", presentationID, globals)
    setup.message(object: 2, opcode: 0) {
        $0.uint(outputGlobals[0].name)
        $0.string("wl_output")
        $0.uint(outputGlobals[0].version)
        $0.newId(outputAID)
    }
    setup.message(object: 2, opcode: 0) {
        $0.uint(outputGlobals[1].name)
        $0.string("wl_output")
        $0.uint(outputGlobals[1].version)
        $0.newId(outputBID)
    }
    setup.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    setup.message(object: presentationID, opcode: 1) {
        $0.object(surfaceID)
        $0.newId(feedbackID)
    }
    setup.message(object: surfaceID, opcode: 6) { _ in }
    #expect(client.send(setup))
    client.pump()
    _ = client.drainEvents()

    let surface = try #require(compositor.surface(id: surfaceID))
    surface.renderIosurfaceId = 101
    compositor.submitFrame(
        outputID: 11,
        outputGeneration: 1,
        submissionID: 100,
        targetPresentationNs: 1_000,
        sampledIOSurfaceIDs: [101])
    compositor.submitFrame(
        outputID: 22,
        outputGeneration: 1,
        submissionID: 200,
        targetPresentationNs: 2_000,
        sampledIOSurfaceIDs: [101])
    compositor.presentSubmittedFrame(
        outputID: 11,
        outputGeneration: 1,
        submissionID: 100,
        timestampNs: 5_000_000_100,
        refreshNs: 16_666_666,
        sequence: 8,
        flags: 1)
    #expect(WireMessage.first(
        client.drainEvents(), object: feedbackID, opcode: 1) == nil)

    compositor.presentSubmittedFrame(
        outputID: 22,
        outputGeneration: 1,
        submissionID: 200,
        timestampNs: 5_000_000_200,
        refreshNs: 16_666_666,
        sequence: 9,
        flags: 1)
    let events = client.drainEvents()
    #expect(events.filter {
        $0.objectId == feedbackID && $0.opcode == 0
    }.count == 2)
    #expect(WireMessage.first(
        events, object: feedbackID, opcode: 1) != nil)
}
}
