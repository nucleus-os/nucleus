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

// MARK: - Paint content

/// `PaintContentRegistrar` over `SwiftResourceHost.paintContents`. Decodes the
/// wire command span into the Swift `PaintDrawCommand` vocabulary, dropping
/// unknown discriminants.
final class SwiftPaintContentRegistrar: PaintContentRegistrar {
    func register(
        resourceHostHandle: UInt64,
        width: Float,
        height: Float,
        commands: Span<NucleusTypes.PaintCommand>
    ) throws(PaintContentRegistrationError) -> UInt64 {
        if resourceHostHandle == 0 { throw PaintContentRegistrationError.invalidHandle }
        var decoded: [PaintDrawCommand] = []
        decoded.reserveCapacity(commands.count)
        for i in 0..<commands.count {
            let c = commands[i]
            guard let kind = paintDrawCommandKind(c.kind.rawValue) else { continue }
            decoded.append(PaintDrawCommand(
                kind: kind, x: c.x, y: c.y, w: c.w, h: c.h,
                radius: c.radius, strokeWidth: c.strokeWidth, fontSize: c.fontSize,
                color: (c.color.r, c.color.g, c.color.b, c.color.a),
                imageHandle: c.imageHandle, textLayoutHandle: c.textLayoutHandle))
        }
        return SwiftResourceHost.shared.paintContents.register(
            decoded, width: width, height: height).raw
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
