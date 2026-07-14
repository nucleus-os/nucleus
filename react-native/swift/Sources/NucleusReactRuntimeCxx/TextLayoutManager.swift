import CxxStdlib
import NucleusReactRuntimeCxxBridge

// Swift consumers implement this protocol with whatever business
// logic they need to measure Fabric text paragraphs.
public protocol TextLayoutManagerHandler: AnyObject, Sendable {
    func measure(_ request: nucleus.react.TextMeasureRequest) -> nucleus.react.TextMeasureResult
}

// Class wrapper that C++ holds through the emitted
// `NucleusReactRuntimeCxx::SwiftTextLayoutManager`. C++ forwards
// `facebook::react::TextLayoutManager::measure(...)` virtual calls
// into this class via `SwiftTextLayoutManagerBridge` (see
// `swift/Sources/NucleusReactRuntime/cxx/SwiftTextLayoutManagerBridge.cpp`).
//
// `toUnsafe`/`fromUnsafe` mirror the `SwiftMountingObserver` shape:
// Swift hands the C++ factory a retained opaque pointer; the bridge
// `.cpp` calls `fromUnsafe` (exposed via `NucleusReactRuntimeCxx.h`)
// to reclaim the typed Swift instance.
public final class SwiftTextLayoutManager {
    private let handler: any TextLayoutManagerHandler

    public init(_ handler: any TextLayoutManagerHandler) {
        self.handler = handler
    }

    public func measure(_ request: nucleus.react.TextMeasureRequest) -> nucleus.react.TextMeasureResult {
        handler.measure(request)
    }

    public func toUnsafe() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    public static func fromUnsafe(_ pointer: UnsafeMutableRawPointer) -> SwiftTextLayoutManager {
        Unmanaged<SwiftTextLayoutManager>.fromOpaque(pointer).takeRetainedValue()
    }
}
