struct DmabufPlaneLayout: Equatable, Sendable {
    let offset: UInt32
    let stride: UInt32
}

enum DmabufLayoutError: Error, Equatable {
    case incompletePlanes
    case invalidDimensions
    case unsupportedFlags
    case invalidPlaneCount
    case zeroStride
    case undersizedStride
    case layoutOverflow
    case mixedModifiers
}

/// Pure creation-time validation for the packed 32-bit formats Nucleus
/// advertises. Keeping this separate from FD ownership makes all rejection paths
/// deterministic and behavior-testable without manufacturing kernel objects.
enum DmabufLayoutValidator {
    static func validate(
        width: Int32,
        height: Int32,
        flags: UInt32,
        indexedPlanes: [Int: DmabufPlaneLayout]
    ) throws(DmabufLayoutError) -> [DmabufPlaneLayout] {
        guard width > 0, height > 0 else { throw .invalidDimensions }
        guard flags == 0 else { throw .unsupportedFlags }
        let count = indexedPlanes.count
        guard count > 0,
            (0..<count).allSatisfy({ indexedPlanes[$0] != nil })
        else { throw .incompletePlanes }
        guard count == 1 else { throw .invalidPlaneCount }

        let ordered = (0..<count).map { indexedPlanes[$0]! }
        guard let plane = ordered.first, plane.stride != 0 else {
            throw .zeroStride
        }
        let minimumStride = UInt64(UInt32(width)) * 4
        guard UInt64(plane.stride) >= minimumStride else {
            throw .undersizedStride
        }
        _ = try checkedEnd(
            offset: UInt64(plane.offset),
            stride: UInt64(plane.stride),
            height: UInt64(UInt32(height)))
        return ordered
    }

    static func checkedEnd(
        offset: UInt64,
        stride: UInt64,
        height: UInt64
    ) throws(DmabufLayoutError) -> UInt64 {
        let requiredBytes = stride.multipliedReportingOverflow(by: height)
        guard !requiredBytes.overflow else { throw .layoutOverflow }
        let end = offset.addingReportingOverflow(requiredBytes.partialValue)
        guard !end.overflow else { throw .layoutOverflow }
        return end.partialValue
    }

    static func validateModifier(
        current: UInt64?,
        incoming: UInt64
    ) throws(DmabufLayoutError) {
        guard current == nil || current == incoming else {
            throw .mixedModifiers
        }
    }
}
