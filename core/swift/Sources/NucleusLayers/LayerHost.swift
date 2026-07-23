public import NucleusTypes

@MainActor
public final class LayerHost: Layer, ~Sendable {
    public init(context: Context, targetContextID: ContextID, frame: GeometryRect = .zero) {
        super.init(
            context: context,
            id: context.allocateLayerID(),
            descriptor: LayerDescriptor(kind: .host, frame: frame, targetContextID: targetContextID)
        )
        context.layers[id] = self
    }
}
