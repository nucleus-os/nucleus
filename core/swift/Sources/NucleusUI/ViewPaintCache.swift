@_spi(NucleusCompositor) internal import NucleusLayers
internal import enum NucleusTypes.PaintBlendMode
internal import enum NucleusTypes.PaintCommandKind
internal import enum NucleusTypes.PaintShading
internal import struct NucleusTypes.Color
internal import struct NucleusTypes.PaintCommand
internal import struct NucleusTypes.PaintCommandFlags

extension ViewLayerPublisher {
    struct PaintCacheKey: Hashable {
        var widthBits: UInt32
        var heightBits: UInt32
        var digest: Int
    }

    struct PaintCacheEntry {
        var recording: PaintRecording
        var registered: RegisteredPaint
        var acceptedReferenceCount: Int
    }

    struct PaintReferenceChange {
        var key: PaintCacheKey
        var recording: PaintRecording
        var delta: Int
    }

    func publishPaint(
        snapshot: ViewLayerSnapshot,
        state: inout VisualLayerCache,
        transaction: inout LayerTransaction,
        cacheDelta: inout PublicationCacheDelta,
        didMutate: inout Bool,
        metrics: inout ViewPublicationMetrics
    ) throws(LayerError) {
        let width = Float(snapshot.frame.width)
        let height = Float(snapshot.frame.height)
        let recording = snapshot.recording

        if recording.isEmpty {
            if !state.paintRecording.isEmpty {
                stagePaintReferenceRemoval(
                    for: state,
                    cacheDelta: &cacheDelta)
                transaction.mutations.append(.properties(
                    layer: state.layer.id,
                    LayerPropertyUpdate(content: LayerContent.none)
                ))
                state.paintWidth = nil
                state.paintHeight = nil
                state.paintRecording = PaintRecording()
                state.paintCacheKey = nil
                didMutate = true
            }
            return
        }

        guard state.paintWidth != width ||
                state.paintHeight != height ||
                state.paintRecording != recording
        else {
            return
        }

        let cacheKey = paintCacheKey(
            recording: recording,
            width: width,
            height: height)
        metrics.recordingsHashed &+= 1
        metrics.paintPayloadBytesHashed &+= UInt64(recording.payload.count)
        let registered: RegisteredPaint
        if let cached = cacheDelta.paintInsertions[cacheKey]?.first(where: {
            $0.recording == recording
        }) ?? paintCache[cacheKey]?.first(where: {
            $0.recording == recording
        }) {
            registered = cached.registered
            metrics.contentCacheHits &+= 1
        } else {
            guard let textSystem = semanticContext?.services.textSystem else {
                throw LayerError.backendFailure(
                    detail: "paint publication has no semantic text system")
            }
            registered = try PaintRegistration.register(
                recording,
                width: width,
                height: height,
                in: context,
                textSystem: textSystem
            )
            cacheDelta.paintInsertions[cacheKey, default: []].append(PaintCacheEntry(
                recording: recording,
                registered: registered,
                acceptedReferenceCount: 0))
            metrics.contentRegistrations &+= 1
            metrics.registrationsCreated &+= 1
        }
        stagePaintReferenceRemoval(
            for: state,
            cacheDelta: &cacheDelta)
        cacheDelta.paintReferenceChanges.append(PaintReferenceChange(
            key: cacheKey,
            recording: recording,
            delta: 1))
        var update = registered.update
        let canLocalize =
            state.paintWidth == width
                && state.paintHeight == height
                && !state.paintRecording.isEmpty
        if canLocalize, let damage = snapshot.paintDamage {
            update.contentDamage = damage.geometryRect
            metrics.localizedPaintUpdates &+= 1
            metrics.damageRegions &+= 1
        } else {
            update.contentDamage = nil
            metrics.fullPaintUpdates &+= 1
        }
        transaction.mutations.append(.properties(
            layer: state.layer.id,
            update
        ))
        state.paintWidth = width
        state.paintHeight = height
        state.paintRecording = recording
        state.paintCacheKey = cacheKey
        didMutate = true
        metrics.paintBytes &+= UInt64(recording.payload.count)
            &+ UInt64(recording.commands.count)
                &* UInt64(MemoryLayout<PaintCommand>.stride)
    }

    func stagePaintReferenceRemoval(
        for state: VisualLayerCache,
        cacheDelta: inout PublicationCacheDelta
    ) {
        guard
            let key = state.paintCacheKey,
            !state.paintRecording.isEmpty
        else { return }
        cacheDelta.paintReferenceChanges.append(PaintReferenceChange(
            key: key,
            recording: state.paintRecording,
            delta: -1))
    }

    func applyPaintCacheDelta(
        _ cacheDelta: PublicationCacheDelta
    ) {
        var touchedKeys = Set(cacheDelta.paintInsertions.keys)
        for (key, entries) in cacheDelta.paintInsertions {
            paintCache[key, default: []].append(contentsOf: entries)
            retainedPaintRegistrationCountStorage += entries.count
        }
        for change in cacheDelta.paintReferenceChanges {
            touchedKeys.insert(change.key)
            guard
                let index = paintCache[change.key]?.firstIndex(where: {
                    $0.recording == change.recording
                })
            else {
                preconditionFailure("accepted paint reference has no cache entry")
            }
            paintCache[change.key]?[index].acceptedReferenceCount += change.delta
        }
        for key in touchedKeys {
            let countBeforeReclamation = paintCache[key]?.count ?? 0
            paintCache[key]?.removeAll {
                precondition(
                    $0.acceptedReferenceCount >= 0,
                    "paint cache reference count became negative")
                return $0.acceptedReferenceCount == 0
            }
            retainedPaintRegistrationCountStorage -=
                countBeforeReclamation - (paintCache[key]?.count ?? 0)
            if paintCache[key]?.isEmpty == true {
                paintCache[key] = nil
            }
        }
        precondition(
            retainedPaintRegistrationCountStorage >= 0,
            "retained paint registration count became negative")
    }

    func paintCacheKey(
        recording: PaintRecording,
        width: Float,
        height: Float
    ) -> PaintCacheKey {
        var hasher = Hasher()
        hasher.combine(recording.commands.count)
        hasher.combine(recording.payload.count)
        for command in recording.commands {
            hasher.combine(command.kind.rawValue)
            hasher.combine(command.flags.rawValue)
            hasher.combine(command.shading.rawValue)
            hasher.combine(command.blend.rawValue)
            hasher.combine(command.x.bitPattern)
            hasher.combine(command.y.bitPattern)
            hasher.combine(command.w.bitPattern)
            hasher.combine(command.h.bitPattern)
            hasher.combine(command.radius.bitPattern)
            hasher.combine(command.strokeWidth.bitPattern)
            hasher.combine(command.fontSize.bitPattern)
            hasher.combine(command.alpha.bitPattern)
            hasher.combine(command.blurSigma.bitPattern)
            hasher.combine(command.saturation.bitPattern)
            hasher.combine(command.color.r.bitPattern)
            hasher.combine(command.color.g.bitPattern)
            hasher.combine(command.color.b.bitPattern)
            hasher.combine(command.color.a.bitPattern)
            hasher.combine(command.imageHandle)
            hasher.combine(command.textLayoutHandle)
            hasher.combine(command.effectHandle)
            hasher.combine(command.payloadOffset)
            hasher.combine(command.payloadLength)
            hasher.combine(command.transformA.bitPattern)
            hasher.combine(command.transformB.bitPattern)
            hasher.combine(command.transformC.bitPattern)
            hasher.combine(command.transformD.bitPattern)
            hasher.combine(command.transformTX.bitPattern)
            hasher.combine(command.transformTY.bitPattern)
        }
        for byte in recording.payload {
            hasher.combine(byte)
        }
        for layout in recording.textLayouts {
            hasher.combine(layout.text)
            hasher.combine(layout.lines.count)
        }
        return PaintCacheKey(
            widthBits: width.bitPattern,
            heightBits: height.bitPattern,
            digest: hasher.finalize())
    }
}
