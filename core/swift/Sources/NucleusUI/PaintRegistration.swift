import NucleusLayers
import NucleusTypes

/// Registered paint content plus the layer update that binds it.
///
/// Owning: it holds the registered `PaintContent` and any transient text-layout
/// handles alive until it is deallocated. A caller must keep it alive until the
/// update has been appended to a transaction or applied to a layer — releasing
/// early would drop the content's last reference before the compositor reads it.
package final class RegisteredPaint {
    /// The property update binding the registered content, ready to apply.
    package let update: NucleusLayers.LayerPropertyUpdate

    private let content: PaintContent?
    private let transientTextHandles: [UInt64]

    init(update: NucleusLayers.LayerPropertyUpdate, content: PaintContent?, transientTextHandles: [UInt64]) {
        self.update = update
        self.content = content
        self.transientTextHandles = transientTextHandles
    }

    deinit {
        for handle in transientTextHandles {
            TextSystem.shared.releaseLayoutHandle(handle)
        }
        withExtendedLifetime(content) {}
    }
}

/// Lowering and registration for one recorded drawing, independent of the view
/// tree.
///
/// This is the single path from a `PaintRecording` to a `NucleusLayers.LayerPropertyUpdate`.
/// `ViewLayerPublisher` calls it from its diff path; the React Native mount
/// path calls the same unit rather than duplicating the lowering, which is what
/// let the parallel committer exist in the first place.
///
/// Host-facing SPI, not product API: a client authoring a `View` subclass sees
/// `GraphicsContext` and never a recording, layer, context, or registrar.
package enum PaintRegistration {
    /// Register `recording` at the given authored size and return the update
    /// that binds it. An empty recording produces the clear-content update, so
    /// a view that stops drawing releases its content rather than keeping the
    /// last frame.
    @MainActor
    package static func register(
        _ recording: PaintRecording,
        width: Float,
        height: Float,
        in context: Context
    ) throws(LayerError) -> RegisteredPaint {
        guard !recording.isEmpty else {
            return RegisteredPaint(
                update: NucleusLayers.LayerPropertyUpdate(content: LayerContent.none),
                content: nil,
                transientTextHandles: [])
        }

        // Resolve recording-local text-layout indices to registry handles. A
        // layout with backing storage vends a stable handle; otherwise a
        // transient one is minted here and released when this value dies —
        // never during recording, so recordings stay comparable.
        var transient: [UInt64] = []
        var commands = recording.commands
        for i in commands.indices where commands[i].kind == .textLayout {
            let index = Int(commands[i].textLayoutHandle)
            guard index > 0, index <= recording.textLayouts.count else {
                commands[i].textLayoutHandle = 0
                continue
            }
            let layout = recording.textLayouts[index - 1]
            if let stable = layout.storage?.retainedHandle(), stable != 0 {
                commands[i].textLayoutHandle = stable
            } else {
                let handle = TextSystem.shared.makeLayoutHandle(for: layout)
                commands[i].textLayoutHandle = handle
                if handle != 0 { transient.append(handle) }
            }
        }

        let content = try PaintContent.register(
            commands,
            payload: recording.payload,
            width: width,
            height: height,
            in: context)
        return RegisteredPaint(
            update: NucleusLayers.LayerPropertyUpdate(content: LayerContent(content)),
            content: content,
            transientTextHandles: transient)
    }
}
