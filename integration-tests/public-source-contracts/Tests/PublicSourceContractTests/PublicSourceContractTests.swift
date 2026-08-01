import FoundationClient
import Testing

@Test
func foundationFacadeConstructsCanonicalValues() {
    let (color, rect) = makeFoundationValues()
    #expect(color.a == 1)
    #expect(rect.size.width == 40)
}
