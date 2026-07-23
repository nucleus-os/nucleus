@_spi(NucleusCompositor) internal import NucleusLayers
internal import enum NucleusTypes.LayerKind
internal import struct NucleusTypes.Point
internal import struct NucleusTypes.Rect
internal import struct NucleusTypes.Size

extension ViewLayerPublisher {
    struct AuthoredPropertyUpdate {
        var generation: UInt64
        var sequence: Int
        var update: LayerPropertyUpdate
    }

    func propertyUpdates(
        for snapshot: ViewLayerSnapshot,
        state: inout VisualLayerCache
    ) -> [LayerPropertyUpdate] {
        var authored: [AuthoredPropertyUpdate] = []
        var sequence = 0

        func append(
            _ update: LayerPropertyUpdate,
            domain: ViewDirtyDomain
        ) {
            authored.append(AuthoredPropertyUpdate(
                generation: snapshot.dirtyGenerations[domain],
                sequence: sequence,
                update: update
            ))
            sequence += 1
        }

        let frame = snapshot.frame.geometryRect
        if state.frame != frame {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .geometry, snapshot: snapshot)
            )
            update.position = GeometryPoint(x: frame.x, y: frame.y)
            update.bounds = GeometrySize(
                width: frame.width,
                height: frame.height
            )
            if snapshot.clipsToBounds {
                update.clip = ClipOp(
                    rectX: 0,
                    rectY: 0,
                    rectW: Float(snapshot.frame.width),
                    rectH: Float(snapshot.frame.height)
                )
            }
            state.frame = frame
            append(update, domain: .geometry)
        }

        let opacityChanged = state.opacity != snapshot.opacity
        let hiddenChanged = state.isHidden != snapshot.isHidden
        if opacityChanged || hiddenChanged {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .visibility, snapshot: snapshot)
            )
            if hiddenChanged {
                update.opacity = snapshot.isHidden ? 0 : snapshot.opacity
            } else if !snapshot.isHidden {
                update.opacity = snapshot.opacity
            }
            state.opacity = snapshot.opacity
            state.isHidden = snapshot.isHidden
            if update.opacity != nil {
                append(update, domain: .visibility)
            }
        }

        if state.boundsOrigin != snapshot.boundsOrigin {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .scrolling, snapshot: snapshot)
            )
            update.scrollOffset = GeometryPoint(
                x: snapshot.boundsOrigin.x,
                y: snapshot.boundsOrigin.y
            )
            state.boundsOrigin = snapshot.boundsOrigin
            append(update, domain: .scrolling)
        }

        if state.transform != snapshot.transform {
            var update = LayerPropertyUpdate(
                actionPolicy: policy(for: .transform, snapshot: snapshot)
            )
            update.transform = snapshot.transform.layersTransform
            state.transform = snapshot.transform
            append(update, domain: .transform)
        }

        var styleUpdate = LayerPropertyUpdate(
            actionPolicy: policy(for: .style, snapshot: snapshot)
        )
        var styleChanged = false
        if state.clipsToBounds != snapshot.clipsToBounds {
            let size = snapshot.clipsToBounds ? snapshot.frame : SnapshotRect(
                x: 0, y: 0, width: 0, height: 0)
            styleUpdate.clip = ClipOp(
                rectX: 0,
                rectY: 0,
                rectW: Float(size.width),
                rectH: Float(size.height)
            )
            state.clipsToBounds = snapshot.clipsToBounds
            styleChanged = true
        }
        if state.cornerRadius != snapshot.cornerRadius {
            styleUpdate.cornerRadii = CornerRadii(
                uniform: Float(snapshot.cornerRadius)
            )
            state.cornerRadius = snapshot.cornerRadius
            styleChanged = true
        }
        if state.shadow != snapshot.shadow {
            styleUpdate.shadow = (snapshot.shadow ?? .none).layersShadow
            state.shadow = snapshot.shadow
            styleChanged = true
        }
        if state.backdropGroup != snapshot.backdropGroup {
            styleUpdate.backdropGroupID = snapshot.backdropGroup.rawValue
            state.backdropGroup = snapshot.backdropGroup
            styleChanged = true
        }
        if snapshot.layerKind == .backdrop,
           state.backdropMaterial != snapshot.backdropMaterial
        {
            styleUpdate.backdropMaterial = snapshot.backdropMaterial
            state.backdropMaterial = snapshot.backdropMaterial
            styleChanged = true
        }
        if styleChanged {
            append(styleUpdate, domain: .style)
        }

        return authored.sorted {
            if $0.generation != $1.generation {
                return $0.generation < $1.generation
            }
            return $0.sequence < $1.sequence
        }.map(\.update)
    }

    func policy(
        for domain: ViewDirtyDomain,
        snapshot: ViewLayerSnapshot
    ) -> NucleusLayers.ActionPolicy {
        (snapshot.actionPolicies[domain] ?? .none).layersPolicy
    }
}
