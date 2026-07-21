import Foundation
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

    @Test func checkedLayoutArithmeticMatchesBoundedIntegerProperties() {
        var random = DmabufRandom(seed: dmabufPropertySeed())
        for _ in 0..<4_096 {
            let offset = random.next()
            let stride = random.next()
            let height = random.next()
            let product = stride.multipliedReportingOverflow(by: height)
            let expected = product.overflow
                ? nil
                : offset.addingReportingOverflow(product.partialValue)
            let shouldOverflow = product.overflow || expected?.overflow == true
            do {
                let end = try DmabufLayoutValidator.checkedEnd(
                    offset: offset,
                    stride: stride,
                    height: height)
                #expect(!shouldOverflow)
                #expect(end == expected?.partialValue)
            } catch {
                #expect(error == .layoutOverflow)
                #expect(shouldOverflow)
            }
        }
    }
}

private func dmabufPropertySeed() -> UInt64 {
    guard let value = ProcessInfo.processInfo.environment["NUCLEUS_TEST_SEED"]
    else { return 0x444d_4142_5546_4c59 }
    let digits = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
    return UInt64(digits, radix: 16) ?? 0x444d_4142_5546_4c59
}

private struct DmabufRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
