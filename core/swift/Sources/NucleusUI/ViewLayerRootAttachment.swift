@_spi(NucleusCompositor) package import NucleusLayers

extension ViewLayerPublisher {
    package func ensureRootAttached() throws(UIError) -> Layer {
        let root = ensureRootLayer()
        guard !rootCreated || !rootAttached else { return root }

        var transaction = LayerTransaction(context: context)
        if !rootCreated {
            transaction.mutations.append(.created(root.id, root.descriptor))
        }
        if !rootAttached {
            transaction.mutations.append(
                .inserted(layer: root.id, parent: nil, index: UInt32.max))
        }

        do {
            try transaction.commit()
            applyAcceptedMutations(transaction.mutations)
            rootCreated = true
            rootAttached = true
            return root
        } catch let error {
            transaction.abort()
            discardUnacceptedRootIfNeeded()
            throw UIError(error)
        }
    }

    func ensureRootLayer() -> Layer {
        if let rootLayer { return rootLayer }
        let root = context.makeLayer(.init(frame: .zero, opacity: 1))
        rootLayer = root
        return root
    }

    func discardUnacceptedRootIfNeeded() {
        guard !rootCreated, let rootLayer else { return }
        context.layers.removeValue(forKey: rootLayer.id)
        self.rootLayer = nil
    }

    /// Mirror an accepted journal into the producer model only after the commit
    /// sink accepts it.
    func applyAcceptedMutations(_ mutations: [LayerMutation]) {
        for mutation in mutations {
            switch mutation {
            case .created:
                break
            case .inserted(let layerID, let parentID, let index):
                guard let layer = context.layers[layerID] else { continue }
                let parent = parentID.flatMap { context.layers[$0] }
                layer.attach(to: parent, at: index)
            case .properties(let layerID, let update):
                context.layers[layerID]?.apply(update)
            case .detached(let layerID):
                context.layers[layerID]?.detach()
            case .removed(let layerID):
                context.layers[layerID]?.detach()
                context.layers.removeValue(forKey: layerID)
            case .animationAdded, .animationRemoved:
                break
            }
        }
    }
}
