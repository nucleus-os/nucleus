public import NucleusTypes
import NucleusAppHostProtocols

// `ContentKind` is wire-owned (the generated discriminant enum). The domain
// `LayerContent` is kept (it carries the non-wire `resourceHostHandle` plus
// retain/release lifecycle); its `.wireValue`/`init(wireValue:)` live in
// DirectBridge.swift.
public typealias ContentKind = NucleusTypes.ContentKind

public struct LayerContent: Sendable, Equatable {
    public var kind: ContentKind
    public var handle: UInt64
    package var resourceHostHandle: UInt64 = 0
    package var resourceLifetime: LayerResourceLifetime?

    public static let none = LayerContent(kind: .none, handle: 0)

    public init(kind: ContentKind, handle: UInt64, resourceHostHandle: UInt64 = 0) {
        self.kind = kind
        self.handle = handle
        self.resourceHostHandle = resourceHostHandle
        self.resourceLifetime = nil
    }

    public init(_ paint: PaintContent) {
        self.init(kind: .paint, handle: paint.handle, resourceHostHandle: paint.resourceHostHandle)
        resourceLifetime = paint.resourceLifetime
    }

    public init(_ snapshot: SnapshotContent) {
        self.init(kind: .snapshot, handle: snapshot.handle, resourceHostHandle: snapshot.resourceHostHandle)
        resourceLifetime = snapshot.resourceLifetime
    }

    public init(_ ioSurface: IOSurfaceContent) {
        self.init(kind: .external, handle: ioSurface.handle)
        resourceLifetime = ioSurface.resourceLifetime
    }

    public static func == (lhs: LayerContent, rhs: LayerContent) -> Bool {
        lhs.kind == rhs.kind
            && lhs.handle == rhs.handle
            && lhs.resourceHostHandle == rhs.resourceHostHandle
    }

    package func retainHandle() {
        guard handle != 0 else {
            return
        }
        switch kind {
        case .paint:
            guard resourceHostHandle != 0 else { return }
            resourceLifetime?.lifecycle.paintContentLifecycle.retain(resourceHostHandle: resourceHostHandle, handle: handle)
        case .external:
            resourceLifetime?.lifecycle.iosurfaceLifecycle.retain(handle: handle)
        case .snapshot:
            guard resourceHostHandle != 0 else { return }
            resourceLifetime?.lifecycle.snapshotLifecycle.retain(resourceHostHandle: resourceHostHandle, handle: handle)
        case .none:
            break
        }
    }

    package func releaseHandle() {
        guard handle != 0 else {
            return
        }
        switch kind {
        case .paint:
            guard resourceHostHandle != 0 else { return }
            resourceLifetime?.lifecycle.paintContentLifecycle.release(resourceHostHandle: resourceHostHandle, handle: handle)
        case .external:
            resourceLifetime?.lifecycle.iosurfaceLifecycle.release(handle: handle)
        case .snapshot:
            guard resourceHostHandle != 0 else { return }
            resourceLifetime?.lifecycle.snapshotLifecycle.release(resourceHostHandle: resourceHostHandle, handle: handle)
        case .none:
            break
        }
    }
}

public final class PaintContent: Sendable {
    public let handle: UInt64
    package let resourceHostHandle: UInt64
    package let resourceLifetime: LayerResourceLifetime?

    public init(
        handle: UInt64, resourceHostHandle: UInt64,
        resourceLifetime: LayerResourceLifetime? = nil,
        retain: Bool = true
    ) {
        self.handle = handle
        self.resourceHostHandle = resourceHostHandle
        self.resourceLifetime = resourceLifetime
        if retain && handle != 0 && resourceHostHandle != 0 {
            resourceLifetime?.lifecycle.paintContentLifecycle.retain(resourceHostHandle: resourceHostHandle, handle: handle)
        }
    }

    deinit {
        if handle != 0 && resourceHostHandle != 0 {
            resourceLifetime?.lifecycle.paintContentLifecycle.release(resourceHostHandle: resourceHostHandle, handle: handle)
        }
    }

    @MainActor
    public static func register(
        _ commands: [PaintCommand], payload: [UInt8] = [],
        width: Float, height: Float, in context: Context
    ) throws(LayerError) -> PaintContent {
        try register(
            commands, payload: payload, width: width, height: height,
            resourceHostHandle: context.commitSink.resourceHostHandle,
            runtimeHost: context.runtimeHost)
    }

    @MainActor
    private static func register(
        _ commands: [PaintCommand], payload: [UInt8],
        width: Float, height: Float,
        resourceHostHandle: UInt64,
        runtimeHost: LayerRuntimeHost
    ) throws(LayerError) -> PaintContent {
        let registrar = runtimeHost.operations.paintContentRegistrar
        var handle: UInt64 = 0
        var error: LayerError?
        withWireRecording(commands, payload) { commandSpan, payloadSpan in
            do {
                handle = try registrar.register(
                    resourceHostHandle: resourceHostHandle,
                    width: width,
                    height: height,
                    commands: commandSpan,
                    payload: payloadSpan
                )
            } catch let err as PaintContentRegistrationError {
                error = paintContentLayerError(from: err)
            } catch let unexpected {
                error = .backendFailure(detail: "register paint content: unexpected error \(unexpected)")
            }
        }
        if let error {
            throw error
        }
        return PaintContent(
            handle: handle,
            resourceHostHandle: resourceHostHandle,
            resourceLifetime: runtimeHost.resourceLifetime,
            retain: false)
    }
}

private func paintContentLayerError(from err: PaintContentRegistrationError) -> LayerError {
    switch err {
    case .invalidHandle:
        return .invalidHandle(detail: "register paint content: invalid resource host handle")
    case .invalidArgument:
        return .invalidArgument(detail: "register paint content: missing commands pointer")
    case .outOfMemory:
        return .outOfMemory
    }
}

public final class SnapshotContent: Sendable {
    public let handle: UInt64
    package let resourceHostHandle: UInt64
    package let resourceLifetime: LayerResourceLifetime?

    public init(
        handle: UInt64, resourceHostHandle: UInt64,
        resourceLifetime: LayerResourceLifetime? = nil,
        retain: Bool = true
    ) {
        self.handle = handle
        self.resourceHostHandle = resourceHostHandle
        self.resourceLifetime = resourceLifetime
        if retain && handle != 0 && resourceHostHandle != 0 {
            resourceLifetime?.lifecycle.snapshotLifecycle.retain(resourceHostHandle: resourceHostHandle, handle: handle)
        }
    }

    deinit {
        if handle != 0 && resourceHostHandle != 0 {
            resourceLifetime?.lifecycle.snapshotLifecycle.release(resourceHostHandle: resourceHostHandle, handle: handle)
        }
    }

}

public final class IOSurfaceContent: Sendable {
    public let handle: UInt64
    package let resourceLifetime: LayerResourceLifetime?

    public init(
        handle: UInt64,
        resourceLifetime: LayerResourceLifetime? = nil,
        retain: Bool = true
    ) {
        self.handle = handle
        self.resourceLifetime = resourceLifetime
        if retain && handle != 0 {
            resourceLifetime?.lifecycle.iosurfaceLifecycle.retain(handle: handle)
        }
    }

    deinit {
        if handle != 0 {
            resourceLifetime?.lifecycle.iosurfaceLifecycle.release(handle: handle)
        }
    }

    @MainActor
    public static func bind(
        id: UInt64, in context: Context
    ) throws(LayerError) -> IOSurfaceContent {
        let binder = context.runtimeHost.operations.iosurfaceBinder
        do {
            let handle = try binder.bind(iosurfaceID: id)
            return IOSurfaceContent(
                handle: handle,
                resourceLifetime: context.runtimeHost.resourceLifetime,
                retain: false)
        } catch let err {
            switch err {
            case .invalidArgument:
                throw LayerError.invalidArgument(detail: "bind iosurface: zero id is reserved")
            }
        }
    }
}

/// Borrow a recording's command and payload arrays for the duration of the
/// synchronous `body` call; the host registrar reads both in place. No element
/// mapping: `PaintCommand` *is* `NucleusTypes.PaintCommand`.
package func withWireRecording<T>(
    _ commands: [PaintCommand],
    _ payload: [UInt8],
    _ body: (Span<NucleusTypes.PaintCommand>, Span<UInt8>) -> T
) -> T {
    body(commands.span, payload.span)
}
