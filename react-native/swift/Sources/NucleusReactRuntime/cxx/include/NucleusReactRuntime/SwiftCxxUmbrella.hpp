#pragma once

// Single umbrella header for bridge `.cpp` files that hold Swift
// instances through the emitted `NucleusReactRuntimeCxx.h`.
//
// The emitted Swift→C++ header references every C++ type any Swift
// public API mentions. If the `.cpp` that includes it doesn't first
// include the headers that define those types, the emitted header
// emits forward references against an empty namespace and compilation
// fails — and every new Swift public type adds another required
// include to every bridge `.cpp` that already exists. This umbrella
// owns that ordering once.
//
// Rule: any new `.cpp` that needs `<NucleusReactRuntimeCxx.h>`
// should include this umbrella instead of the emitted header
// directly. Any new C++ header whose types Swift's public API
// mentions should be added to the block below.
//
// This file is intentionally NOT in `NucleusReactRuntimeCxxBridge.modulemap`
// — including the emitted Swift header through the modulemap forms
// a cycle where the Swift module imports its own emitted output
// during compilation.

#include <NucleusReactRuntime/MountingObserver.hpp>
#include <NucleusReactRuntime/TextLayoutManager.hpp>
#include <NucleusReactRuntime/CxxVirtualOverrideProbe.hpp>

#include <NucleusReactRuntimeCxx.h>
