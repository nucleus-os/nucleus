import Testing
import NucleusReactNativeCxxBridge

// Phase 5 link proof: this test links the full React Native C++ stack — Hermes
// (libhermes_lean.so + libjsi.so) + folly_runtime + glog + fmt + double-conversion,
// all built from the vendored submodules by the Build* command plugins — and runs
// it. A Hermes JSI runtime is created and a global round-trips; folly's
// dynamic+JSON round-trips. Build prerequisites:
//   swift package build-hermes     --allow-writing-to-package-directory
//   swift package build-rn-support --allow-writing-to-package-directory
//   swift package build-rn-cxx     --allow-writing-to-package-directory
@Test func reactNativeCxxStackLinksAndRuns() {
    #expect(nucleus_rn_hermes_runtime_roundtrip(42) == 42)
    #expect(nucleus_rn_folly_roundtrip(7) == 7)
}
