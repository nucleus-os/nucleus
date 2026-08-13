import NucleusAndroidGfxstreamAdaptersTestSupport
import Testing

@unsafe private func expectSuccess(
    _ result: nucleus_android_test_result,
    operation: String
) {
    guard unsafe result.source_line != 0 else { return }
    let check =
        unsafe result.check_name.map { unsafe String(cString: $0) } ?? "unknown check"
    let source =
        unsafe result.source_file.map { unsafe String(cString: $0) } ?? "unknown source"
    let diagnostic =
        unsafe result.diagnostic.map { unsafe String(cString: $0) } ?? "no diagnostic"
    Issue.record(
        "\(operation) failed at \(source):\(unsafe result.source_line): \(check) — \(diagnostic)")
}

@Test func guestRingStreamPreservesByteStreamSemanticsAcrossBackpressure() {
    unsafe expectSuccess(
        unsafe nucleus_android_test_guest_ring_stream(),
        operation: "guest ring stream")
}

@Test func hostRingChannelPumpPreservesPendingTrafficAcrossBackpressure() {
    unsafe expectSuccess(
        unsafe nucleus_android_test_host_ring_channel_pump(),
        operation: "host ring channel pump")
}

@Test func guestRingFactoryInstallsPerConnectionStreams() {
    unsafe expectSuccess(
        unsafe nucleus_android_test_guest_ring_factory_registration(),
        operation: "guest ring factory registration")
}

@Test func ringAdaptersFailClosedWhenEitherPeerDisconnects() {
    unsafe expectSuccess(
        unsafe nucleus_android_test_ring_peer_closure(),
        operation: "ring peer closure")
}
