import Testing
@testable import NucleusCompositorWaylandRuntime

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
