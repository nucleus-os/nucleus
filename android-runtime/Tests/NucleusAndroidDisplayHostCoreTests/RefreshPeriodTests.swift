import NucleusAndroidComposerProtocolC
import Testing

@testable import NucleusAndroidDisplayHostCore

@Test
func waylandMillihertzConvertsToRoundedComposerPeriods() {
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 59_940) == 16_683_350)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 60_000) == 16_666_667)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 120_000) == 8_333_333)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 144_000) == 6_944_444)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 0) == nil)
}

@Test
func resizedPresentationCoordinatesMapBackToAndroidPixels() {
    #expect(
        androidDisplayCoordinate(
            hostCoordinate: 160,
            bufferExtent: 1_280,
            destinationExtent: 640) == 320)
    #expect(
        androidDisplayCoordinate(
            hostCoordinate: 700,
            bufferExtent: 1_280,
            destinationExtent: 640) == 1_279)
    #expect(
        androidDisplayCoordinate(
            hostCoordinate: -5,
            bufferExtent: 720,
            destinationExtent: 360) == 0)
    #expect(
        androidDisplayCoordinate(
            hostCoordinate: .nan,
            bufferExtent: 720,
            destinationExtent: 360) == nil)
}

@Test
func presentationModeComesFromWindowGeometryRatherThanPhysicalOutput() {
    #expect(
        androidPresentationMode(
            configuredWidth: nil,
            configuredHeight: nil
        ) == AndroidPresentationMode(width: 1_280, height: 720))
    #expect(
        androidPresentationMode(
            configuredWidth: 1_440,
            configuredHeight: 900
        ) == AndroidPresentationMode(width: 1_440, height: 900))
}

@Test
func androidResizeKeepsOneRelayoutInFlightAndCoalescesToTheNewestSize() {
    let initial = AndroidPresentationMode(width: 1_280, height: 720)
    let first = AndroidPresentationMode(width: 1_300, height: 740)
    let skipped = AndroidPresentationMode(width: 1_360, height: 800)
    let latest = AndroidPresentationMode(width: 1_440, height: 900)
    var pipeline = AndroidPresentationConfigurationPipeline(
        generation: 1,
        mode: initial)

    #expect(
        pipeline.configure(first)
            == AndroidPresentationConfigurationRequest(
                generation: 2,
                mode: first))
    #expect(pipeline.configure(skipped) == nil)
    #expect(pipeline.configure(latest) == nil)
    #expect(pipeline.pendingMode == latest)
    #expect(
        pipeline.committedFrame(
            generation: 1,
            mode: initial) == nil)
    #expect(
        pipeline.committedFrame(
            generation: 2,
            mode: first)
            == AndroidPresentationConfigurationRequest(
                generation: 3,
                mode: latest))
    #expect(pipeline.pendingMode == nil)
    #expect(
        pipeline.committedFrame(
            generation: 3,
            mode: latest) == nil)
    #expect(!pipeline.configurationInFlight)
}

@Test
func androidResizeCancelsAQueuedSizeWhenTheCompositorReturnsToInFlightSize() {
    let initial = AndroidPresentationMode(width: 1_280, height: 720)
    let inFlight = AndroidPresentationMode(width: 1_360, height: 800)
    let discarded = AndroidPresentationMode(width: 1_440, height: 900)
    var pipeline = AndroidPresentationConfigurationPipeline(
        generation: 8,
        mode: initial)

    #expect(pipeline.configure(inFlight)?.generation == 9)
    #expect(pipeline.configure(discarded) == nil)
    #expect(pipeline.pendingMode == discarded)
    #expect(pipeline.configure(inFlight) == nil)
    #expect(pipeline.pendingMode == nil)
    #expect(
        pipeline.committedFrame(
            generation: 9,
            mode: inFlight) == nil)
    #expect(!pipeline.configurationInFlight)
}

@Test
func androidDensityUsesFractionalOutputScaleAndSharesResizeGeneration() {
    #expect(androidDensityDPI(preferredScale120: 120) == 160)
    #expect(androidDensityDPI(preferredScale120: 180) == 240)
    #expect(androidDensityDPI(preferredScale120: 240) == 320)
    #expect(androidDensityDPI(preferredScale120: 60) == 120)
    #expect(androidDensityDPI(preferredScale120: 600) == 640)
    #expect(androidDensityDPI(preferredScale120: 0) == nil)

    let mode = AndroidPresentationMode(width: 1_280, height: 720)
    var pipeline = AndroidPresentationConfigurationPipeline(
        generation: 4,
        mode: mode)
    #expect(
        pipeline.configure(densityDPI: 240)
            == AndroidPresentationConfigurationRequest(
                generation: 5,
                mode: mode,
                densityDPI: 240))
    #expect(pipeline.committedGeneration == 4)
    #expect(
        pipeline.committedFrame(generation: 5, mode: mode) == nil)
    #expect(pipeline.committedGeneration == 5)
    #expect(pipeline.committedConfiguration.densityDPI == 240)
}

@Test
func androidConfigurationCoalescesSizeAndDensityWithoutDiscardingEither() {
    let initial = AndroidPresentationMode(width: 1_280, height: 720)
    let resized = AndroidPresentationMode(width: 1_440, height: 900)
    var pipeline = AndroidPresentationConfigurationPipeline(
        generation: 2,
        mode: initial)

    #expect(pipeline.configure(densityDPI: 240)?.generation == 3)
    #expect(pipeline.configure(resized) == nil)
    #expect(
        pipeline.pendingConfiguration
            == AndroidPresentationConfiguration(
                mode: resized,
                densityDPI: 240))
    #expect(
        pipeline.committedFrame(generation: 3, mode: initial)
            == AndroidPresentationConfigurationRequest(
                generation: 4,
                mode: resized,
                densityDPI: 240))
}

@Test
func androidPointerIconsMapToWaylandCursorSemantics() {
    #expect(waylandCursorShape(androidPointerIconType: 0) == nil)
    #expect(waylandCursorShape(androidPointerIconType: 1_000) == 1)
    #expect(waylandCursorShape(androidPointerIconType: 1_002) == 4)
    #expect(waylandCursorShape(androidPointerIconType: 1_008) == 9)
    #expect(waylandCursorShape(androidPointerIconType: 1_014) == 26)
    #expect(waylandCursorShape(androidPointerIconType: 1_015) == 27)
    #expect(waylandCursorShape(androidPointerIconType: 1_016) == 28)
    #expect(waylandCursorShape(androidPointerIconType: 1_017) == 29)
    #expect(waylandCursorShape(androidPointerIconType: 1_020) == 16)
    #expect(waylandCursorShape(androidPointerIconType: -1) == 1)
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

    #expect(sixty?.operation == NUCLEUS_COMPOSER_OUTPUT_CONNECTED)
    #expect(oneTwenty?.operation == NUCLEUS_COMPOSER_OUTPUT_CONNECTED)
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
        name: "opaque-name", width: 1440, height: 900,
        refreshMillihertz: 144_000)
    let disconnected = topology.disconnect(name: "opaque-name")
    let duplicateDisconnect = topology.disconnect(name: "opaque-name")
    let reconnected = topology.publish(
        name: "opaque-name", width: 2560, height: 1440,
        refreshMillihertz: 120_000)

    #expect(unchanged == nil)
    #expect(changed?.operation == NUCLEUS_COMPOSER_OUTPUT_MODE_CHANGED)
    #expect(changed?.output.width == 1440)
    #expect(changed?.output.height == 900)
    #expect(disconnected?.operation == NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED)
    #expect(duplicateDisconnect == nil)
    #expect(reconnected?.operation == NUCLEUS_COMPOSER_OUTPUT_CONNECTED)
    #expect(reconnected?.output.displayID == connected?.output.displayID)
    #expect(reconnected?.output.refreshPeriodNanoseconds == 8_333_333)
    #expect(topology.generation == 4)
}
