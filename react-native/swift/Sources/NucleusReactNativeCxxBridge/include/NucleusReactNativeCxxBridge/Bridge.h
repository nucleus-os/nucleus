// C-ABI bridge over the React Native C++ runtime stack (Hermes JSI + folly), so
// Swift can drive it without C++ interop. NucleusReactRuntime links the
// GN/CMake-built Hermes + folly/glog/support libraries and runs JS.
#ifndef NUCLEUS_REACT_RUNTIME_BRIDGE_H
#define NUCLEUS_REACT_RUNTIME_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Create a Hermes JSI runtime and round-trip `value` through a global property
// via jsi (the lean VM runs bytecode, not source — RN ships precompiled bytecode
// — so this exercises the live runtime + jsi without the compiler). Returns the
// read-back number, or NaN on error.
double nucleus_rn_hermes_runtime_roundtrip(double value);

// Exercise folly (dynamic + JSON) to prove folly_runtime links: parses
// {"x":<n>} and returns x, or -1 on mismatch.
int nucleus_rn_folly_roundtrip(int n);

#ifdef __cplusplus
}
#endif

#endif
