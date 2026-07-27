@testable import NucleusAndroidDisplayHostCore
import Testing

@Test
func waylandMillihertzConvertsToRoundedComposerPeriods() {
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 59_940) == 16_683_350)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 60_000) == 16_666_667)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 120_000) == 8_333_333)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 144_000) == 6_944_444)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 0) == nil)
}

@Test
func composerTopologyKeepsIndependentOutputCadencesAndStableIDs() {
    var topology = ComposerOutputTopologyState()
    let sixty = topology.publish(
        name: "output-a", width: 1280, height: 720,
        refreshMillihertz: 60_000)
    let oneTwenty = topology.publish(
        name: "output-b", width: 1280, height: 720,
        refreshMillihertz: 120_000)

    #expect(sixty?.operation.rawValue == 4)
    #expect(oneTwenty?.operation.rawValue == 4)
    #expect(sixty?.output.displayID == 0)
    #expect(oneTwenty?.output.displayID == 1)
    #expect(sixty?.output.refreshPeriodNanoseconds == 16_666_667)
    #expect(oneTwenty?.output.refreshPeriodNanoseconds == 8_333_333)
    #expect(topology.connectedOutputs.map(\.displayID) == [0, 1])
    #expect(topology.generation == 2)
}

@Test
func composerTopologyHandlesModeChangeRemovalAndReconnect() {
    var topology = ComposerOutputTopologyState()
    let connected = topology.publish(
        name: "opaque-name", width: 1920, height: 1080,
        refreshMillihertz: 60_000)
    let unchanged = topology.publish(
        name: "opaque-name", width: 1920, height: 1080,
        refreshMillihertz: 60_000)
    let changed = topology.publish(
        name: "opaque-name", width: 1920, height: 1080,
        refreshMillihertz: 144_000)
    let disconnected = topology.disconnect(name: "opaque-name")
    let duplicateDisconnect = topology.disconnect(name: "opaque-name")
    let reconnected = topology.publish(
        name: "opaque-name", width: 2560, height: 1440,
        refreshMillihertz: 120_000)

    #expect(unchanged == nil)
    #expect(changed?.operation.rawValue == 5)
    #expect(disconnected?.operation.rawValue == 6)
    #expect(duplicateDisconnect == nil)
    #expect(reconnected?.operation.rawValue == 4)
    #expect(reconnected?.output.displayID == connected?.output.displayID)
    #expect(reconnected?.output.refreshPeriodNanoseconds == 8_333_333)
    #expect(topology.generation == 4)
}
