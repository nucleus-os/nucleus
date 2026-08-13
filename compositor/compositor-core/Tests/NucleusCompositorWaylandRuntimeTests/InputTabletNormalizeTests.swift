import Testing

@testable import NucleusCompositorWaylandRuntime

private let tabletDevice = TabletDeviceID(rawValue: 101)
private let tabletTool = TabletToolDescriptor(
    id: TabletToolID(rawValue: 202),
    kind: .pen,
    serial: 303,
    hardwareID: 404,
    capabilities: [.pressure, .tilt])

@Suite struct InputTabletNormalizeTests {
    @Test func toolSequencePreservesTypedAxesAndCancellationOrder() {
        var normalizer = TabletSequenceNormalizer()
        let entered = normalizer.normalize(
            .proximity(
                deviceID: tabletDevice, tool: tabletTool,
                timestampNs: 1, entered: true,
                axes: TabletAxes(x: 10, y: 20, pressure: 0.25)))
        #expect(
            entered == [
                .proximityIn(
                    deviceID: tabletDevice, tool: tabletTool,
                    timestampNs: 1,
                    axes: TabletAxes(x: 10, y: 20, pressure: 0.25))
            ])

        #expect(
            normalizer.normalize(
                .tip(
                    deviceID: tabletDevice, toolID: tabletTool.id,
                    timestampNs: 2, down: true,
                    axes: TabletAxes(pressure: 0.5)))
                == [
                    .tip(
                        deviceID: tabletDevice, toolID: tabletTool.id,
                        timestampNs: 2, down: true,
                        axes: TabletAxes(pressure: 0.5))
                ])

        #expect(
            normalizer.deviceRemoved(tabletDevice) == [
                .tip(
                    deviceID: tabletDevice, toolID: tabletTool.id,
                    timestampNs: 2, down: false, axes: TabletAxes()),
                .proximityOut(
                    deviceID: tabletDevice, toolID: tabletTool.id,
                    timestampNs: 2),
            ])
    }

    @Test func malformedTransitionsRetireTheSequenceExactlyOnce() {
        var normalizer = TabletSequenceNormalizer()
        _ = normalizer.normalize(
            .proximity(
                deviceID: tabletDevice, tool: tabletTool,
                timestampNs: 10, entered: true,
                axes: TabletAxes(x: 1, y: 2)))

        #expect(
            normalizer.normalize(
                .axes(
                    deviceID: tabletDevice, toolID: tabletTool.id,
                    timestampNs: 9, axes: TabletAxes(x: 3, y: 4))) == [
                    .proximityOut(
                        deviceID: tabletDevice, toolID: tabletTool.id,
                        timestampNs: 10)
                ])
        #expect(normalizer.cancelAll().isEmpty)
    }

    @Test func multipleDevicesCancelIndependently() {
        let secondDevice = TabletDeviceID(rawValue: 102)
        let secondTool = TabletToolDescriptor(
            id: TabletToolID(rawValue: 203), kind: .eraser,
            serial: 0, hardwareID: 0, capabilities: [])
        var normalizer = TabletSequenceNormalizer()
        _ = normalizer.normalize(
            .proximity(
                deviceID: tabletDevice, tool: tabletTool,
                timestampNs: 1, entered: true, axes: TabletAxes(x: 1, y: 1)))
        _ = normalizer.normalize(
            .proximity(
                deviceID: secondDevice, tool: secondTool,
                timestampNs: 2, entered: true, axes: TabletAxes(x: 2, y: 2)))

        #expect(
            normalizer.deviceRemoved(secondDevice) == [
                .proximityOut(
                    deviceID: secondDevice, toolID: secondTool.id,
                    timestampNs: 2)
            ])
        #expect(
            normalizer.cancelAll() == [
                .proximityOut(
                    deviceID: tabletDevice, toolID: tabletTool.id,
                    timestampNs: 1)
            ])
    }

    @Test func padControlsRemainIndependentOfToolProximityState() {
        var normalizer = TabletSequenceNormalizer()
        #expect(
            normalizer.normalize(
                .padRing(
                    deviceID: tabletDevice, timestampNs: 50,
                    ring: 1, positionDegrees: nil, source: .finger,
                    group: 2, mode: 3)) == [
                    .padRing(
                        deviceID: tabletDevice, timestampNs: 50,
                        ring: 1, positionDegrees: nil, source: .finger,
                        group: 2, mode: 3)
                ])
    }
}
