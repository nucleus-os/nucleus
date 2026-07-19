// Phase 10c.3 cutover — the Swift-native resource-host conformers.
//
// Each conforms to a `NucleusAppHostProtocols` protocol
// and reads/writes the process-global `SwiftResourceHost.shared` (paint content,
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
    func register(path: String, maxWidth: UInt32, maxHeight: UInt32) throws(ImageRegistrationError) -> UInt64 {
        guard !path.isEmpty else { throw ImageRegistrationError.invalidArgument }
        return SwiftResourceHost.shared.images.register(
            ImageSource(path: path, maxWidth: maxWidth, maxHeight: maxHeight))
    }

    func register(
        encoded: Span<UInt8>, maxWidth: UInt32, maxHeight: UInt32
    ) throws(ImageRegistrationError) -> UInt64 {
        guard !encoded.isEmpty else { throw ImageRegistrationError.invalidArgument }
        var bytes = [UInt8](repeating: 0, count: encoded.count)
        for i in 0..<encoded.count { bytes[i] = encoded[i] }
        return SwiftResourceHost.shared.images.register(
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
        return SwiftResourceHost.shared.images.register(ImageSource(content: .raw(buffer)))
    }
}

/// `ImageLifecycle` over `SwiftResourceHost.images`.
final class SwiftImageLifecycle: ImageLifecycle, @unchecked Sendable {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {
        if resourceHostHandle == 0 { return }
        SwiftResourceHost.shared.images.retain(handle)
    }
    func release(resourceHostHandle: UInt64, handle: UInt64) {
        if resourceHostHandle == 0 { return }
        SwiftResourceHost.shared.images.release(handle)
    }
}

// MARK: - Runtime effects

/// `RuntimeEffectRegistrar` over `SwiftResourceHost.runtimeEffects`.
/// Registration is by SkSL source (the renderer compiles lazily), so it is
/// GPU-independent — the same posture as `SwiftImageRegistrar`.
final class SwiftRuntimeEffectRegistrar: RuntimeEffectRegistrar {
    func register(sksl: String) throws(RuntimeEffectRegistrationError) -> UInt64 {
        guard !sksl.isEmpty else { throw RuntimeEffectRegistrationError.invalidArgument }
        return SwiftResourceHost.shared.runtimeEffects.register(
            RuntimeEffectSource(sksl: sksl))
    }
}

/// `RuntimeEffectLifecycle` over `SwiftResourceHost.runtimeEffects`.
final class SwiftRuntimeEffectLifecycle: RuntimeEffectLifecycle, @unchecked Sendable {
    func retain(handle: UInt64) {
        SwiftResourceHost.shared.runtimeEffects.retain(handle)
    }
    func release(handle: UInt64) {
        SwiftResourceHost.shared.runtimeEffects.release(handle)
    }
}

// MARK: - Paint content

/// Translate the command vocabulary into the render model's. Exhaustive by
/// construction: `NucleusRenderModel` resolves no dependencies, so it cannot
/// share `NucleusTypes`' enums, and these switches carry no `default` — adding
/// a kind or blend mode is a compile error at every site that must learn it.
private func paintDrawCommandKind(_ kind: NucleusTypes.PaintCommandKind) -> PaintDrawCommandKind {
    switch kind {
    case .rect: .rect
    case .roundedRect: .roundedRect
    case .image: .image
    case .path: .path
    case .clipPath: .clipPath
    case .save: .save
    case .restore: .restore
    case .textLayout: .textLayout
    }
}

private func paintDrawShading(_ shading: NucleusTypes.PaintShading) -> PaintDrawShading {
    switch shading {
    case .color: .color
    case .linearGradient: .linearGradient
    case .radialGradient: .radialGradient
    case .sweepGradient: .sweepGradient
    case .effect: .effect
    }
}

private func paintDrawBlendMode(_ blend: NucleusTypes.PaintBlendMode) -> PaintDrawBlendMode {
    switch blend {
    case .srcOver: .srcOver
    case .src: .src
    case .multiply: .multiply
    case .screen: .screen
    case .plus: .plus
    case .overlay: .overlay
    case .dstIn: .dstIn
    case .dstOut: .dstOut
    }
}

/// `PaintContentRegistrar` over `SwiftResourceHost.paintContents`. Decodes the
/// command span into the Swift `PaintDrawCommand` vocabulary. An unknown
/// discriminant is no longer representable, so no draw can be silently dropped.
final class SwiftPaintContentRegistrar: PaintContentRegistrar {
    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>,
        payload: Span<UInt8>
    ) throws(PaintContentRegistrationError) -> UInt64 {
        if resourceHostHandle == 0 { throw PaintContentRegistrationError.invalidHandle }
        var decoded: [PaintDrawCommand] = []
        decoded.reserveCapacity(commands.count)
        for i in 0..<commands.count {
            let c = commands[i]
            decoded.append(PaintDrawCommand(
                kind: paintDrawCommandKind(c.kind),
                x: c.x, y: c.y, w: c.w, h: c.h,
                radius: c.radius, strokeWidth: c.strokeWidth, fontSize: c.fontSize,
                color: (c.color.r, c.color.g, c.color.b, c.color.a),
                imageHandle: c.imageHandle, textLayoutHandle: c.textLayoutHandle,
                effectHandle: c.effectHandle,
                payloadOffset: c.payloadOffset, payloadLength: c.payloadLength,
                stroke: c.flags.contains(.stroke),
                antialias: c.flags.contains(.antialias),
                evenOddFill: c.flags.contains(.evenOddFill),
                tintsImage: c.flags.contains(.tintImage),
                strokeCap: c.flags.contains(.capRound) ? .round
                    : (c.flags.contains(.capSquare) ? .square : .butt),
                strokeJoin: c.flags.contains(.joinRound) ? .round
                    : (c.flags.contains(.joinBevel) ? .bevel : .miter),
                transform: c.flags.contains(.hasTransform)
                    ? PaintDrawTransform(
                        a: c.transformA, b: c.transformB, c: c.transformC,
                        d: c.transformD, tx: c.transformTX, ty: c.transformTY)
                    : nil,
                shading: paintDrawShading(c.shading),
                blend: paintDrawBlendMode(c.blend),
                alpha: c.alpha, blurSigma: c.blurSigma, saturation: c.saturation))
        }
        var payloadBytes = [UInt8]()
        payloadBytes.reserveCapacity(payload.count)
        for i in 0..<payload.count { payloadBytes.append(payload[i]) }
        return SwiftResourceHost.shared.paintContents.register(
            decoded, payload: payloadBytes, width: width, height: height).raw
    }
}

/// `PaintContentLifecycle` over `SwiftResourceHost.paintContents`.
final class SwiftPaintContentLifecycle: PaintContentLifecycle, @unchecked Sendable {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {
        if resourceHostHandle == 0 { return }
        SwiftResourceHost.shared.paintContents.retain(PaintContentHandle(raw: handle))
    }
    func release(resourceHostHandle: UInt64, handle: UInt64) {
        if resourceHostHandle == 0 { return }
        SwiftResourceHost.shared.paintContents.release(PaintContentHandle(raw: handle))
    }
}

// MARK: - Snapshots

/// `SnapshotLifecycle` over `SwiftResourceHost.snapshots`. Release drops the
/// snapshot's backing texture handle (the renderer's registry release is driven
/// by the renderer-side `releaseSnapshot`; here we only drop the metadata ref).
final class SwiftSnapshotLifecycle: SnapshotLifecycle, @unchecked Sendable {
    func retain(resourceHostHandle: UInt64, handle: UInt64) {
        if resourceHostHandle == 0 { return }
        SwiftResourceHost.shared.snapshots.retain(SnapshotHandle(raw: handle))
    }
    func release(resourceHostHandle: UInt64, handle: UInt64) {
        if resourceHostHandle == 0 { return }
        _ = SwiftResourceHost.shared.snapshots.release(SnapshotHandle(raw: handle))
    }
}

// MARK: - Implicit actions

/// `ImplicitActionRegistrar` over `SwiftResourceHost.implicitActions`. Decodes
/// the wire rows into the model's implicit-action template table.
final class SwiftImplicitActionRegistrar: ImplicitActionRegistrar {
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
        SwiftResourceHost.shared.implicitActions.replace(decoded)
    }
}
