import NucleusTypes
import NucleusCompositorServerTypes
@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorServer

/// Two batched witness calls implementing `BackdropResolver.resolveBackdrops`:
/// frame-start identity/material resolution and post-walk spatial resolution.
extension WindowManager {
    public func backdropResolveMaterials(
        inputs: UnsafePointer<WireBackdropMaterialInput>?,
        inputsLen: UInt32,
        keyWindowID: UInt64,
        accessibility: WireBackdropAccessibility,
        frameTime: Double
    ) throws(HostCallError) -> [WireBackdropMaterialSpec] {
        let identities: [BackdropResolver.Identity] = decodeMaterialInputs(inputs, count: Int(inputsLen))
        let acc = BackdropPolicy.Accessibility(
            reduceTransparency: accessibility.reduceTransparency,
            systemAppearance: decodeSystemAppearance(accessibility.systemAppearance)
        )
        let records = backdropResolver.resolveBackdrops(
            identities: identities,
            keyWindowID: keyWindowID == 0 ? nil : keyWindowID,
            accessibility: acc,
            increaseContrast: accessibility.increaseContrast,
            frameTime: frameTime
        )
        return records.map(encodeMaterialSpec)
    }

    public func backdropPolicyResolve(
        inputs: UnsafePointer<WireBackdropLayerInput>?,
        inputsLen: UInt32
    ) throws(HostCallError) -> [WireBackdropDraw] {
        let draws = backdropResolver.resolveSpatial(
            geometries: decodeLayerInputs(inputs, count: Int(inputsLen))
        )
        return draws.map { encodeDraw($0) }
    }
}

// MARK: - Encoders

@MainActor
private func decodeLayerInputs(
    _ ptr: UnsafePointer<WireBackdropLayerInput>?,
    count: Int
) -> [BackdropResolver.GeometryInput] {
    guard let ptr, count > 0 else { return [] }
    var out: [BackdropResolver.GeometryInput] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        let raw = ptr[i]
        out.append(BackdropResolver.GeometryInput(
            layerID: raw.layerId,
            frame: .init(
                x: raw.frameX,
                y: raw.frameY,
                width: raw.frameWidth,
                height: raw.frameHeight
            ),
            isOpaqueOccluder: raw.isOpaqueOccluder,
            producerGroupID: raw.producerGroupId,
        ))
    }
    return out
}

@MainActor
private func decodeMaterialInputs(
    _ ptr: UnsafePointer<WireBackdropMaterialInput>?,
    count: Int
) -> [BackdropResolver.Identity] {
    guard let ptr, count > 0 else { return [] }
    return (0..<count).map { index in
        let raw = ptr[index]
        return .init(
            layerID: raw.layerId,
            material: BackdropMaterialKind(rawValue: raw.material) ?? .none,
            requestedState: BackdropState(rawValue: raw.requestedState) ?? .active,
            appearance: BackdropAppearance(rawValue: raw.appearance) ?? .auto,
            isEmphasized: raw.isEmphasized,
            owningWindowID: raw.hasOwningWindow ? raw.owningWindowId : nil,
            tint: SIMD4(raw.tintR, raw.tintG, raw.tintB, raw.tintA),
            opacity: raw.opacity
        )
    }
}

private func decodeSystemAppearance(_ raw: UInt8) -> BackdropPolicy.ResolvedAppearance {
    switch raw {
    case 2: return .dark
    default: return .light
    }
}

@MainActor
private func encodeDraw(_ draw: BackdropPolicy.Draw) -> WireBackdropDraw {
    WireBackdropDraw(
        layerId: draw.layerID,
        regionX: draw.region.x,
        regionY: draw.region.y,
        regionWidth: draw.region.width,
        regionHeight: draw.region.height,
        groupId: draw.groupID,
        resolvedState: draw.resolvedState.rawValue,
        resolvedAppearance: draw.resolvedAppearance.rawValue,
        reserved0: 0,
        reserved1: 0,
        reserved2: 0
    )
}

private func encodeMaterialSpec(_ record: ResolvedBackdropMaterialRecord) -> WireBackdropMaterialSpec {
    let value = record.material
    return WireBackdropMaterialSpec(
        layerId: record.layerID,
        enabled: value.enabled,
        passes: value.passes,
        foregroundVariant: value.foregroundVariant.rawValue,
        resolvedAppearance: value.resolvedAppearance.rawValue,
        resolvedState: value.resolvedState.rawValue,
        needsFrame: record.needsFrame,
        reserved0: 0,
        reserved1: 0,
        offset: value.offset,
        saturation: value.saturation,
        tintR: value.tint.x, tintG: value.tint.y, tintB: value.tint.z, tintA: value.tint.w,
        tintBlend: value.tintBlend,
        noise: value.noise,
        alpha: value.alpha,
        solidFallbackR: value.solidFallback.x,
        solidFallbackG: value.solidFallback.y,
        solidFallbackB: value.solidFallback.z,
        solidFallbackA: value.solidFallback.w
    )
}
