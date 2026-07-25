//
// Each conforms to a `NucleusAppHostProtocols` protocol
// and reads/writes its explicitly owned `SwiftResourceHost` (paint content,
// images, snapshots, implicit actions) — the GPU-independent Swift stores the
// renderer reads at frame time. The host-bundle install wires these into the
// resource-host slots.

import NucleusTypes
import NucleusAppHostProtocols
import NucleusRenderModel

// MARK: - Images

/// `ImageRegistrar` over `SwiftResourceHost.images`. Registration is by file
/// path + decode bounds (the renderer decodes lazily), so it is GPU-independent.
final class SwiftImageRegistrar: ImageRegistrar {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func register(path: String, maxWidth: UInt32, maxHeight: UInt32) throws(ImageRegistrationError) -> UInt64 {
        guard !path.isEmpty, maxWidth > 0, maxHeight > 0
        else { throw ImageRegistrationError.invalidArgument }
        guard resourceHost.isLive else { throw .invalidHandle }
        return resourceHost.images.register(
            ImageSource(path: path, maxWidth: maxWidth, maxHeight: maxHeight))
    }

    func register(
        encoded: Span<UInt8>, maxWidth: UInt32, maxHeight: UInt32
    ) throws(ImageRegistrationError) -> UInt64 {
        guard !encoded.isEmpty, maxWidth > 0, maxHeight > 0
        else { throw ImageRegistrationError.invalidArgument }
        var bytes = [UInt8](repeating: 0, count: encoded.count)
        for i in 0..<encoded.count { bytes[i] = encoded[i] }
        guard resourceHost.isLive else { throw .invalidHandle }
        return resourceHost.images.register(
            ImageSource(content: .encoded(bytes: bytes), maxWidth: maxWidth, maxHeight: maxHeight))
    }

    func register(
        pixels: Span<UInt8>, width: UInt32, height: UInt32, rowStride: UInt32,
        channelOrder: UInt8, isPremultiplied: Bool
    ) throws(ImageRegistrationError) -> UInt64 {
        guard !pixels.isEmpty, width > 0, height > 0,
              let order = PixelChannelOrder(rawValue: channelOrder)
        else { throw ImageRegistrationError.invalidArgument }

        var bytes = [UInt8](repeating: 0, count: pixels.count)
        for i in 0..<pixels.count { bytes[i] = pixels[i] }
        let buffer = RawPixelBuffer(
            width: Int(width), height: Int(height), rowStride: Int(rowStride),
            order: order, isPremultiplied: isPremultiplied, pixels: bytes)
        // Reject a buffer that does not describe itself consistently here, rather
        // than registering a handle that can only ever fail to draw.
        guard buffer.isWellFormed else { throw ImageRegistrationError.invalidArgument }
        guard resourceHost.isLive else { throw .invalidHandle }
        return resourceHost.images.register(ImageSource(content: .raw(buffer)))
    }
}

/// `ImageLifecycle` over `SwiftResourceHost.images`.
final class SwiftImageLifecycle: ImageLifecycle {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func retain(resourceHostHandle: UInt64, handle: UInt64) {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else { return }
        resourceHost.images.retain(handle)
    }
    func release(resourceHostHandle: UInt64, handle: UInt64) {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else { return }
        resourceHost.images.release(handle)
    }
}

// MARK: - Runtime effects

/// `RuntimeEffectRegistrar` over `SwiftResourceHost.runtimeEffects`.
/// Registration is by SkSL source (the renderer compiles lazily), so it is
/// GPU-independent — the same posture as `SwiftImageRegistrar`.
final class SwiftRuntimeEffectRegistrar: RuntimeEffectRegistrar {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func register(sksl: String) throws(RuntimeEffectRegistrationError) -> UInt64 {
        guard !sksl.isEmpty else { throw RuntimeEffectRegistrationError.invalidArgument }
        guard resourceHost.isLive else { throw .invalidHandle }
        return resourceHost.runtimeEffects.register(
            RuntimeEffectSource(sksl: sksl))
    }
}

/// `RuntimeEffectLifecycle` over `SwiftResourceHost.runtimeEffects`.
final class SwiftRuntimeEffectLifecycle: RuntimeEffectLifecycle {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func retain(handle: UInt64) {
        guard resourceHost.isLive else { return }
        resourceHost.runtimeEffects.retain(handle)
    }
    func release(handle: UInt64) {
        guard resourceHost.isLive else { return }
        resourceHost.runtimeEffects.release(handle)
    }
}

// MARK: - Paint content

/// Copy one borrowed contiguous span into owned storage. The callback exists so
/// behavioral tests can count the single bulk initialization operation without
/// inspecting implementation shape.
func copyContiguousSpan<Element>(
    _ source: Span<Element>,
    didInitialize: (Int) -> Void = { _ in }
) -> [Element] {
    source.withUnsafeBufferPointer { source in
        unsafe Array<Element>(
            unsafeUninitializedCapacity: source.count
        ) { destination, initializedCount in
            guard source.count > 0 else {
                initializedCount = 0
                return
            }
            unsafe destination.baseAddress!.initialize(
                from: source.baseAddress!,
                count: source.count)
            initializedCount = source.count
            didInitialize(source.count)
        }
    }
}

/// `PaintContentRegistrar` over `SwiftResourceHost.paintContents`. Validation
/// happens before either contiguous copy, so rejected input cannot become
/// partially registered content.
final class SwiftPaintContentRegistrar: PaintContentRegistrar {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>,
        payload: Span<UInt8>
    ) throws(PaintContentRegistrationError) -> UInt64 {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else {
            throw PaintContentRegistrationError.invalidHandle
        }
        for i in 0..<commands.count {
            let command = commands[i]
            guard command.hasValidFlags,
                  command.hasValidPayloadRange(count: payload.count)
            else {
                throw PaintContentRegistrationError.invalidArgument
            }
        }

        let storedCommands = copyContiguousSpan(commands)
        let payloadBytes = copyContiguousSpan(payload)
        return resourceHost.paintContents.register(
            storedCommands, payload: payloadBytes,
            width: width, height: height).raw
    }
}

/// `PaintContentLifecycle` over `SwiftResourceHost.paintContents`.
final class SwiftPaintContentLifecycle: PaintContentLifecycle {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func retain(resourceHostHandle: UInt64, handle: UInt64) {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else { return }
        resourceHost.paintContents.retain(PaintContentHandle(raw: handle))
    }
    func release(resourceHostHandle: UInt64, handle: UInt64) {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else { return }
        resourceHost.paintContents.release(PaintContentHandle(raw: handle))
    }
}

// MARK: - Snapshots

/// `SnapshotLifecycle` over `SwiftResourceHost.snapshots`. Release drops the
/// snapshot's backing texture handle (the renderer's registry release is driven
/// by the renderer-side `releaseSnapshot`; here we only drop the metadata ref).
final class SwiftSnapshotLifecycle: SnapshotLifecycle {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func retain(resourceHostHandle: UInt64, handle: UInt64) {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else { return }
        resourceHost.snapshots.retain(SnapshotHandle(raw: handle))
    }
    func release(resourceHostHandle: UInt64, handle: UInt64) {
        guard resourceHost.accepts(rawIdentity: resourceHostHandle) else { return }
        _ = resourceHost.snapshots.release(SnapshotHandle(raw: handle))
    }
}

// MARK: - Implicit actions

/// `ImplicitActionRegistrar` over `SwiftResourceHost.implicitActions`. Decodes
/// the wire rows into the model's implicit-action template table.
final class SwiftImplicitActionRegistrar: ImplicitActionRegistrar {
    private let resourceHost: SwiftResourceHost

    init(resourceHost: SwiftResourceHost) {
        self.resourceHost = resourceHost
    }

    func register(rows: Span<NucleusTypes.ImplicitActionRow>) {
        var decoded: [NucleusRenderModel.ImplicitActionRow] = []
        decoded.reserveCapacity(rows.count)
        for i in 0..<rows.count {
            let r = rows[i]
            guard let role = NucleusRenderModel.LayerRole(rawValue: r.role.rawValue),
                  let keyPath = NucleusRenderModel.ImplicitActionKeyPath(rawValue: r.keyPath.rawValue),
                  let kind = NucleusRenderModel.ImplicitActionKind(rawValue: r.kind.rawValue) else { continue }
            decoded.append(NucleusRenderModel.ImplicitActionRow(
                role: role, keyPath: keyPath, kind: kind,
                mass: r.mass, stiffness: r.stiffness, damping: r.damping, duration: r.duration,
                c1x: r.c1x, c1y: r.c1y, c2x: r.c2x, c2y: r.c2y))
        }
        var table = ImplicitActionTable()
        table.replace(decoded)
        guard resourceHost.isLive else { return }
        resourceHost.replaceImplicitActions(table)
    }
}
