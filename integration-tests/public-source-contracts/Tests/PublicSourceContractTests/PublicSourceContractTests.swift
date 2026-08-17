import AndroidRuntimeCoreClient
import DesktopClient
import FoundationClient
import PortableAuthoringClient
import ReactRuntimeClient
import SessionProtocolClient
import Testing

@Test
func foundationFacadeConstructsCanonicalValues() {
    let (color, rect) = makeFoundationValues()
    #expect(color.a == 1)
    #expect(rect.size.width == 40)
}

@Test
@MainActor
func deploymentProductsExposeTheirSupportedContracts() {
    #expect(androidPackageArchitecture() == .arm64)
    #expect(makeSessionMilestone() == .compositorReady)
    _ = makeDesktopConfiguration()
    _ = makePortableViewHierarchy
    _ = makeReactRuntimeHost
}
