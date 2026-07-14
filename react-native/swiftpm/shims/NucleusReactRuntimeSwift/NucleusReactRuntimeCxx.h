// Shim: the cxx host's SwiftCxxUmbrella.hpp includes <NucleusReactRuntimeCxx.h>,
// but SwiftPM emits the Swift->C++ header as <NucleusReactRuntimeCxx-Swift.h>
// (in GeneratedModuleMaps-<triple>/). Bridge the name.
#pragma once
#include <NucleusReactRuntimeCxx-Swift.h>
