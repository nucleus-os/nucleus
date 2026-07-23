import Testing
@testable import NucleusCompositorWaylandRuntime

private final class RecordingActivationDelegate: XdgActivationDelegate {
    var activations: [(surfaceID: UInt32?, token: String)] = []

    func activateSurface(_ surface: WlSurface?, token: String) {
        activations.append((surface?.objectId, token))
    }
}

@Test
func activationTokensHaveUniqueOpaqueRandomPayloads() {
    let manager = XdgActivationManager()
    var tokens: Set<String> = []

    for _ in 0..<1_024 {
        let token = manager.mintToken(authorized: true)
        #expect(token.utf8.count == 32)
        #expect(token.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        })
        tokens.insert(token)
    }

    #expect(tokens.count == 1_024)
}

@Test
func activationTokenGrantsAreOneShot() {
    let manager = XdgActivationManager()
    let authorized = manager.mintToken(authorized: true)
    let unauthorized = manager.mintToken(authorized: false)

    #expect(manager.consumeToken(authorized))
    #expect(!manager.consumeToken(authorized))
    #expect(!manager.consumeToken(unauthorized))
}

@Test
func activationTokenGenerationRetriesAnActiveCollision() {
    var candidates = ["collision", "collision", "replacement"]
    let manager = XdgActivationManager(tokenGenerator: {
        candidates.removeFirst()
    })

    #expect(manager.mintToken(authorized: true) == "collision")
    #expect(manager.mintToken(authorized: true) == "replacement")
}

@MainActor @Test
func activationTokensRemainOpaqueAndOneShotAcrossTheWaylandWire() throws {
    let graph = WaylandTestGraph()
    let router = try #require(NucleusWaylandRouter())
    let compositor = graph.compositor()
    let manager = XdgActivationManager()
    let delegate = RecordingActivationDelegate()
    manager.delegate = delegate
    compositor.register(in: router)
    manager.register(in: router)

    let client = try #require(WaylandTestClient(display: router.display))
    let globals = client.globals()
    func bind(
        _ builder: inout WireBuilder,
        interface: String,
        id: UInt32
    ) throws {
        let global = try #require(
            globals.first { $0.interface == interface })
        builder.message(object: 2, opcode: 0) {
            $0.uint(global.name)
            $0.string(interface)
            $0.uint(global.version)
            $0.newId(id)
        }
    }

    let compositorID: UInt32 = 3
    let activationManagerID: UInt32 = 4
    let surfaceID: UInt32 = 5
    let tokenID: UInt32 = 6
    var setup = WireBuilder()
    try bind(&setup, interface: "wl_compositor", id: compositorID)
    try bind(
        &setup,
        interface: "xdg_activation_v1",
        id: activationManagerID)
    setup.message(object: compositorID, opcode: 0) {
        $0.newId(surfaceID)
    }
    setup.message(object: activationManagerID, opcode: 1) {
        $0.newId(tokenID)
    }
    setup.message(object: tokenID, opcode: 3) { _ in }
    #expect(client.send(setup))
    client.pump()
    let events = client.drainEvents()
    let committedToken = try #require(
        WireMessage.first(events, object: tokenID, opcode: 0)?.string(0))
    #expect(committedToken.utf8.count == 32)

    // A commit without a seat serial receives an opaque but ineffective token.
    var invalidActivation = WireBuilder()
    invalidActivation.message(object: activationManagerID, opcode: 2) {
        $0.string(committedToken)
        $0.object(surfaceID)
    }
    #expect(client.send(invalidActivation))
    client.pump()
    #expect(delegate.activations.isEmpty)

    // An authorized grant crosses the same wire once and cannot be replayed.
    let authorizedToken = manager.mintToken(authorized: true)
    var activation = WireBuilder()
    activation.message(object: activationManagerID, opcode: 2) {
        $0.string(authorizedToken)
        $0.object(surfaceID)
    }
    activation.message(object: activationManagerID, opcode: 2) {
        $0.string(authorizedToken)
        $0.object(surfaceID)
    }
    #expect(client.send(activation))
    client.pump()
    #expect(delegate.activations.count == 1)
    #expect(delegate.activations.first?.surfaceID == surfaceID)
    #expect(delegate.activations.first?.token == authorizedToken)
}
