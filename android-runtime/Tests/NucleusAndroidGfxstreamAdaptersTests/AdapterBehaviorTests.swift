import NucleusAndroidGfxstreamAdaptersTestSupport
import Testing

@Test func guestRingStreamPreservesByteStreamSemanticsAcrossBackpressure() {
    #expect(nucleus_android_test_guest_ring_stream() == 0)
}

@Test func hostRingChannelPumpPreservesPendingTrafficAcrossBackpressure() {
    #expect(nucleus_android_test_host_ring_channel_pump() == 0)
}

@Test func guestRingFactoryInstallsPerConnectionStreams() {
    #expect(nucleus_android_test_guest_ring_factory_registration() == 0)
}

@Test func ringAdaptersFailClosedWhenEitherPeerDisconnects() {
    #expect(nucleus_android_test_ring_peer_closure() == 0)
}
