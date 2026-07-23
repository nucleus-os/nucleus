import Testing
import NucleusReactNativeCxxBridge

// (libhermes_lean.so + libjsi.so) + folly_runtime + glog + fmt + double-conversion,
// all built from the vendored submodules by Collider — and runs
// it. A Hermes JSI runtime is created and a global round-trips; folly's
// dynamic+JSON round-trips. Build prerequisite: tools/collider bootstrap rn
@Test func reactNativeCxxStackLinksAndRuns() {
    #expect(nucleus_rn_hermes_runtime_roundtrip(42) == 42)
    #expect(nucleus_rn_folly_roundtrip(7) == 7)
}
