import CxxStdlib

// Swift side of the C++→Swift bridge probe. C++ holds an instance of
// this class through `NucleusReactRuntimeCxx::ProbeSwiftHandler`
// (declared in the emitted `NucleusReactRuntimeCxx.h`) and forwards
// virtual `Observer::notify(...)` calls into it. See
// `swift/Sources/NucleusReactRuntime/cxx/CxxVirtualOverrideBridge.cpp`.
//
// `toUnsafe`/`fromUnsafe` mirror Nitro's `Unmanaged` round-trip:
// Swift hands the C++ factory a retained opaque pointer; the bridge
// `.cpp` calls `fromUnsafe` (defined here, exposed via
// `NucleusReactRuntimeCxx.h`) to reclaim the typed Swift instance.
public final class ProbeSwiftHandler {
    public private(set) var received: [String] = []

    public init() {}

    public func notify(_ message: std.string) {
        received.append(String(message))
    }

    public func toUnsafe() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    public static func fromUnsafe(_ pointer: UnsafeMutableRawPointer) -> ProbeSwiftHandler {
        Unmanaged<ProbeSwiftHandler>.fromOpaque(pointer).takeRetainedValue()
    }
}
