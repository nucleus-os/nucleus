import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite struct DmabufLayoutValidatorTests {
    private static let valid = [0: DmabufPlaneLayout(offset: 0, stride: 64)]

    @Test func validPackedLayoutIsAccepted() throws {
        let planes = try DmabufLayoutValidator.validate(
            width: 16, height: 8, flags: 0, indexedPlanes: Self.valid)
        #expect(planes == [DmabufPlaneLayout(offset: 0, stride: 64)])
    }

    @Test func gapsAndExcessPlanesAreRejected() {
        #expect(throws: DmabufLayoutError.incompletePlanes) {
            try DmabufLayoutValidator.validate(
                width: 4, height: 4, flags: 0,
                indexedPlanes: [1: DmabufPlaneLayout(offset: 0, stride: 16)])
        }
        #expect(throws: DmabufLayoutError.invalidPlaneCount) {
            try DmabufLayoutValidator.validate(
                width: 4, height: 4, flags: 0,
                indexedPlanes: [
                    0: DmabufPlaneLayout(offset: 0, stride: 16),
                    1: DmabufPlaneLayout(offset: 0, stride: 16),
                ])
        }
    }

    @Test func dimensionsFlagsAndStrideAreValidated() {
        #expect(throws: DmabufLayoutError.invalidDimensions) {
            try DmabufLayoutValidator.validate(
                width: 0, height: 4, flags: 0, indexedPlanes: Self.valid)
        }
        #expect(throws: DmabufLayoutError.unsupportedFlags) {
            try DmabufLayoutValidator.validate(
                width: 4, height: 4, flags: 1, indexedPlanes: Self.valid)
        }
        #expect(throws: DmabufLayoutError.zeroStride) {
            try DmabufLayoutValidator.validate(
                width: 4, height: 4, flags: 0,
                indexedPlanes: [0: DmabufPlaneLayout(offset: 0, stride: 0)])
        }
        #expect(throws: DmabufLayoutError.undersizedStride) {
            try DmabufLayoutValidator.validate(
                width: 17, height: 4, flags: 0, indexedPlanes: Self.valid)
        }
    }

    @Test func offsetPlusPlaneBytesCannotOverflow() {
        #expect(throws: DmabufLayoutError.layoutOverflow) {
            try DmabufLayoutValidator.checkedEnd(
                offset: 1, stride: UInt64.max, height: 2)
        }
        #expect(throws: DmabufLayoutError.layoutOverflow) {
            try DmabufLayoutValidator.checkedEnd(
                offset: UInt64.max, stride: 1, height: 1)
        }
    }

    @Test func allPlanesMustUseOneModifier() throws {
        try DmabufLayoutValidator.validateModifier(current: nil, incoming: 3)
        try DmabufLayoutValidator.validateModifier(current: 3, incoming: 3)
        #expect(throws: DmabufLayoutError.mixedModifiers) {
            try DmabufLayoutValidator.validateModifier(
                current: 3, incoming: 4)
        }
    }
}
