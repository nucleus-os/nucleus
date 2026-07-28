import Testing
@testable import NucleusLinuxAccessibility

@Suite struct AtSPIWireBoundaryTests {
    @Test func geometryConversionIsTotalAndSaturating() {
        #expect(atSPIWireInt32(.nan) == 0)
        #expect(atSPIWireInt32(.infinity) == .max)
        #expect(atSPIWireInt32(-.infinity) == .min)
        #expect(atSPIWireInt32(Double.greatestFiniteMagnitude) == .max)
        #expect(atSPIWireInt32(-Double.greatestFiniteMagnitude) == .min)
        #expect(atSPIWireInt32(42.9) == 42)
        #expect(atSPIWireInt32(-42.9) == -42)
        #expect(atSPIWireInt32(Double(Int32.max)) == .max)
        #expect(atSPIWireInt32(Double(Int32.min)) == .min)
    }
}
