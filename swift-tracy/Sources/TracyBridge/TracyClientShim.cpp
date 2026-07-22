// Tracy client compiled as a single translation unit (#include "TracyClient.cpp"
// resolved through the header search path into the pinned third-party/tracy
// submodule so its protocol matches the tracy-capture receiver).
//
// Co-located in the TracyBridge target — rather than a standalone Tracy
// target — because SwiftBuild does not propagate a C++ target's archive to the
// executable through the cxx-interop import chain: the ___tracy_* symbols must
// live in the same archive as TraceBridge.cpp, which the Swift side links
// directly. A separate target compiles fine but silently drops out of the link.
//
// The whole client is inert unless TRACY_ENABLE is defined; pass
// `-Xcc -DTRACY_ENABLE` to `swift build` (`tools/nucleus run --tracy` does)
// to compile it in. Without the flag TracyClient.cpp is empty.
#include "TracyClient.cpp"
