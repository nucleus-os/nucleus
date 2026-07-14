import CxxStdlib
import NucleusReactRuntimeCxxBridge

// Swift consumers implement this protocol with whatever business
// logic they need to react to Fabric mount mutations. The bridge
// calls `didMount` once per mutation in a transaction, then
// `didFinishTransaction` once at the end so consumers can materialize
// the batch as a single unit.
public protocol MountingObserverHandler: AnyObject, Sendable {
    func didMount(_ mutation: nucleus.react.MountMutation)
    func didFinishTransaction(surfaceID: Int32)
}

// Class wrapper that C++ holds through the emitted
// `NucleusReactRuntimeCxx::SwiftMountingObserver`. C++ forwards
// `MountingObserver::didMount(...)` virtual calls into this class
// via `SwiftMountingObserverBridge` (see
// `swift/Sources/NucleusReactRuntime/cxx/SwiftMountingObserverBridge.cpp`).
//
// `toUnsafe`/`fromUnsafe` mirror Nitro's `Unmanaged` round-trip:
// Swift hands the C++ factory a retained opaque pointer; the bridge
// `.cpp` calls `fromUnsafe` (exposed via `NucleusReactRuntimeCxx.h`)
// to reclaim the typed Swift instance.
public final class SwiftMountingObserver {
    private let handler: any MountingObserverHandler

    public init(_ handler: any MountingObserverHandler) {
        self.handler = handler
    }

    public func didMount(_ mutation: nucleus.react.MountMutation) {
        handler.didMount(mutation)
    }

    public func didFinishTransaction(surfaceID: Int32) {
        handler.didFinishTransaction(surfaceID: surfaceID)
    }

    public func toUnsafe() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    public static func fromUnsafe(_ pointer: UnsafeMutableRawPointer) -> SwiftMountingObserver {
        Unmanaged<SwiftMountingObserver>.fromOpaque(pointer).takeRetainedValue()
    }
}
