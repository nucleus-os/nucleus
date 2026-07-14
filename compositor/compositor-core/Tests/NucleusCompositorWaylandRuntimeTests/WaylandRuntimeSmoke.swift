// Exercises the Wayland runtime foundation end-to-end on libwayland, in the
// production shape the swap uses: a global binds to a Swift owner, a client
// request routes through libwayland's vtable to a Swift handler, the handler
// recovers its owner from the resource's user_data (Rule 9 borrow) and creates a
// child resource with its own owner, and destroying that child runs the owner's
// deinit (Rule 9: destruction invalidates the owner). The "client" is an
// in-process raw-wire sender over a socketpair (only -lwayland-server is linked).

import Glibc
import WaylandServerC
import WaylandServer

// Semantic owners. CompositorOwner holds per-compositor state; SurfaceOwner's
// deinit stands in for semantic surface teardown.
final class CompositorOwner {
    var surfaceCount = 0
}
final class SurfaceOwner {
    deinit { g_surfaceTeardown += 1 }
}

nonisolated(unsafe) var g_compositorBindCount = 0
nonisolated(unsafe) var g_surfaceCreated = 0
nonisolated(unsafe) var g_surfaceTeardown = 0
nonisolated(unsafe) var g_recoveredSurfaceCount = -1
nonisolated(unsafe) var g_lastSurface: UnsafeMutablePointer<wl_resource>? = nil
nonisolated(unsafe) var g_compositorVtable: UnsafeMutableRawPointer? = nil

private let createSurface: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<wl_resource>?, UInt32
) -> Void = { client, compositorRes, id in
    guard let client, let compositorRes else { return }
    // Recover the owner bound to the compositor resource (Rule 9 borrow) and
    // mutate its state, proving user_data round-trips to the same Swift instance.
    if let owner = WaylandResource.owner(of: compositorRes, as: CompositorOwner.self) {
        owner.surfaceCount += 1
        g_recoveredSurfaceCount = owner.surfaceCount
    }
    // Create the child wl_surface with its own owner. It takes no requests in
    // this test, so no vtable is attached.
    g_lastSurface = WaylandResource.create(
        client: client, interface: swift_wayland_iface_wl_surface(),
        version: 6, id: id, vtable: nil, owner: SurfaceOwner()
    )
    g_surfaceCreated += 1
}

private let createRegion: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<wl_resource>?, UInt32
) -> Void = { _, _, _ in }

private let compositorBind: @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
) -> Void = { client, _, version, id in
    g_compositorBindCount += 1
    guard let client else { return }
    _ = WaylandResource.create(
        client: client, interface: swift_wayland_iface_wl_compositor(),
        version: Int32(version), id: id, vtable: g_compositorVtable.map(UnsafeRawPointer.init),
        owner: CompositorOwner()
    )
}

// ── raw wire builder (in-process client) ─────────────────────────────────────

private func appendU32(_ out: inout [UInt8], _ v: UInt32) {
    out.append(UInt8(v & 0xff))
    out.append(UInt8((v >> 8) & 0xff))
    out.append(UInt8((v >> 16) & 0xff))
    out.append(UInt8((v >> 24) & 0xff))
}

private func appendString(_ out: inout [UInt8], _ s: String) {
    let utf8 = Array(s.utf8)
    let len = utf8.count + 1
    appendU32(&out, UInt32(len))
    out.append(contentsOf: utf8)
    out.append(0)
    let pad = (4 - (len % 4)) % 4
    for _ in 0..<pad { out.append(0) }
}

private func appendMessage(
    _ out: inout [UInt8], objectId: UInt32, opcode: UInt16,
    _ buildArgs: (inout [UInt8]) -> Void
) {
    var payload = [UInt8]()
    buildArgs(&payload)
    let size = UInt32(8 + payload.count)
    appendU32(&out, objectId)
    appendU32(&out, (size << 16) | UInt32(opcode))
    out.append(contentsOf: payload)
}

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandRuntimeSmoke {
    static func main() {
        // Build the compositor request vtable once (zero-init + field assignment;
        // its memberwise initializer is unusable under C++ interop).
        let vtSize = MemoryLayout<swift_wayland_wl_compositor_requests>.stride
        let vtRaw = UnsafeMutableRawPointer.allocate(
            byteCount: vtSize, alignment: MemoryLayout<swift_wayland_wl_compositor_requests>.alignment
        )
        vtRaw.initializeMemory(as: UInt8.self, repeating: 0, count: vtSize)
        let vt = vtRaw.bindMemory(to: swift_wayland_wl_compositor_requests.self, capacity: 1)
        vt.pointee.create_surface = createSurface
        vt.pointee.create_region = createRegion
        g_compositorVtable = vtRaw

        guard let display = WaylandDisplay() else { fail("WaylandDisplay") }
        // The global must outlive dispatch — WaylandGlobal.deinit destroys it, so
        // a discarded temporary would be torn down before the client can bind.
        guard let global = WaylandGlobal(
            display: display, interface: swift_wayland_iface_wl_compositor(),
            version: 6, bind: compositorBind
        ) else { fail("WaylandGlobal") }
        defer { withExtendedLifetime(global) {} }

        var sv: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sv) == 0 else {
            fail("socketpair")
        }
        guard display.createClient(fd: sv[0]) != nil else { fail("createClient") }

        // wl_display(1).get_registry(new_id=2); wl_registry(2).bind(name=2,
        // "wl_compositor", v6, new_id=3); wl_compositor(3).create_surface(new_id=4).
        // Global name 2: wl_display_init_shm registers wl_shm as name 1 during
        // WaylandDisplay init, so this fixture's compositor is the second global.
        var bytes = [UInt8]()
        appendMessage(&bytes, objectId: 1, opcode: 1) { appendU32(&$0, 2) }
        appendMessage(&bytes, objectId: 2, opcode: 0) {
            appendU32(&$0, 2)
            appendString(&$0, "wl_compositor")
            appendU32(&$0, 6)
            appendU32(&$0, 3)
        }
        appendMessage(&bytes, objectId: 3, opcode: 0) { appendU32(&$0, 4) }

        let written = bytes.withUnsafeBytes { write(sv[1], $0.baseAddress, $0.count) }
        guard written == bytes.count else { fail("partial write \(written)/\(bytes.count)") }

        for _ in 0..<16 {
            display.dispatch()
            if g_surfaceCreated > 0 { break }
        }

        guard g_compositorBindCount == 1 else { fail("bind=\(g_compositorBindCount)") }
        guard g_surfaceCreated == 1 else { fail("surfaceCreated=\(g_surfaceCreated)") }
        guard g_recoveredSurfaceCount == 1 else {
            fail("owner round-trip recoveredSurfaceCount=\(g_recoveredSurfaceCount)")
        }

        // Rule 9: destroying the resource must run the owner's teardown exactly once.
        guard let surface = g_lastSurface else { fail("no surface resource") }
        wl_resource_destroy(surface)
        guard g_surfaceTeardown == 1 else { fail("surfaceTeardown=\(g_surfaceTeardown)") }

        print("OK wayland runtime bind=\(g_compositorBindCount) "
            + "surface_create=\(g_surfaceCreated) owner_roundtrip=\(g_recoveredSurfaceCount) "
            + "destroy_teardown=\(g_surfaceTeardown)")
        close(sv[1])
    }
}
