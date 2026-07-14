import NucleusReactFabricSmokeC

// Test-only headless smoke for the *full* Fabric runtime, driven through the real
// RuntimeHost — which wires the mounting observer + SwiftTextLayoutManager that
// installFabric() requires (the raw-facade C smoke skips installFabric for that
// reason). Proves the statically-linked fabric installs the Fabric UIManager and
// evaluates bytecode headless (single-threaded; no compositor loop). Implemented via
// `@c @implementation` against the existing `smoke.h` declaration, so the signature
// is type-checked against the C header (and the test still calls it through that plain
// C declaration — no cxx facade module reaches the synthesized test runner). Returns 0
// on success.
@c @implementation
public func nucleus_rn_fabric_full_smoke(_ hbcPath: UnsafePointer<CChar>?) -> Int32 {
    guard let hbcPath else { return 1 }
    let path = String(cString: hbcPath)
    return MainActor.assumeIsolated {
        do {
            let host = try RuntimeHost()
            try host.installFabric()
            try host.evaluateBytecode(at: path)
            _ = try host.drainPendingJSCalls()
            return 0
        } catch {
            return 2
        }
    }
}
