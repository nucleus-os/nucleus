import Glibc
import Testing
import WaylandServerC
@testable import NucleusCompositorWaylandRuntime

@MainActor
private final class GammaControlTestDelegate: GammaControlDelegate {
    var applied: ([UInt16], [UInt16], [UInt16])?
    var clearCount = 0

    func gammaRampSize(output _: WlOutput?) -> UInt32 { 16 }

    func gammaApply(
        output _: WlOutput?,
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16]
    ) {
        applied = (red, green, blue)
    }

    func gammaClear(output _: WlOutput?) {
        clearCount += 1
    }
}

@MainActor
private func bindGammaGlobal(
    _ builder: inout WireBuilder,
    interface: String,
    id: UInt32,
    globals: [(name: UInt32, interface: String, version: UInt32)]
) throws {
    let global = try #require(
        globals.first { $0.interface == interface })
    builder.message(object: 2, opcode: 0) {
        $0.uint(global.name)
        $0.string(interface)
        $0.uint(global.version)
        $0.newId(id)
    }
}

@MainActor
@Suite(.serialized)
struct GammaControlTests {
    @Test func rampReadCompletesOffActorAndAppliesOnActor() async throws {
        let router = try #require(NucleusWaylandRouter())
        let delegate = GammaControlTestDelegate()
        let output = WlOutput(info: OutputInfo(
            physicalWidthMm: 600,
            physicalHeightMm: 340,
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshMhz: 60_000,
            scale: 1,
            name: "GAMMA-TEST",
            description: "Gamma Test Output"))
        output.register(in: router)
        let manager = ZwlrGammaControlManager()
        manager.delegate = delegate
        manager.register(in: router)

        let client = try #require(
            WaylandTestClient(display: router.display))
        let globals = client.globals()
        let managerID: UInt32 = 3
        let outputID: UInt32 = 4
        let controlID: UInt32 = 5
        var construction = WireBuilder()
        try bindGammaGlobal(
            &construction,
            interface: "zwlr_gamma_control_manager_v1",
            id: managerID,
            globals: globals)
        try bindGammaGlobal(
            &construction,
            interface: "wl_output",
            id: outputID,
            globals: globals)
        construction.message(object: managerID, opcode: 0) {
            $0.newId(controlID)
            $0.object(outputID)
        }
        #expect(client.send(construction))
        client.pump()
        _ = client.drainEvents()

        let channel = (0..<16).map { UInt16($0 * 257) }
        let values = channel + channel + channel
        let descriptor = unsafe memfd_create("nucleus-gamma-test", 0)
        #expect(descriptor >= 0)
        let written = values.withUnsafeBytes {
            unsafe write(descriptor, $0.baseAddress, $0.count)
        }
        #expect(written == values.count * MemoryLayout<UInt16>.stride)
        let ownedDescriptor = OwnedTestFD(descriptor)
        var request = WireBuilder()
        request.message(object: controlID, opcode: 0) { _ in }
        try client.send(request, fd: ownedDescriptor)

        client.pump()
        #expect(delegate.applied == nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while delegate.applied == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let applied = try #require(delegate.applied)
        #expect(applied.0 == channel)
        #expect(applied.1 == channel)
        #expect(applied.2 == channel)
    }

    @Test func malformedRampFailsAndClearsTheActiveControl() async throws {
        let router = try #require(NucleusWaylandRouter())
        let delegate = GammaControlTestDelegate()
        let output = WlOutput(info: OutputInfo(
            physicalWidthMm: 600,
            physicalHeightMm: 340,
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshMhz: 60_000,
            scale: 1,
            name: "GAMMA-INVALID",
            description: "Gamma Invalid Output"))
        output.register(in: router)
        let manager = ZwlrGammaControlManager()
        manager.delegate = delegate
        manager.register(in: router)

        let client = try #require(
            WaylandTestClient(display: router.display))
        let globals = client.globals()
        let managerID: UInt32 = 3
        let outputID: UInt32 = 4
        let controlID: UInt32 = 5
        var construction = WireBuilder()
        try bindGammaGlobal(
            &construction,
            interface: "zwlr_gamma_control_manager_v1",
            id: managerID,
            globals: globals)
        try bindGammaGlobal(
            &construction,
            interface: "wl_output",
            id: outputID,
            globals: globals)
        construction.message(object: managerID, opcode: 0) {
            $0.newId(controlID)
            $0.object(outputID)
        }
        #expect(client.send(construction))
        client.pump()
        _ = client.drainEvents()

        let descriptor = unsafe memfd_create("nucleus-gamma-invalid", 0)
        #expect(descriptor >= 0)
        let ownedDescriptor = OwnedTestFD(descriptor)
        var request = WireBuilder()
        request.message(object: controlID, opcode: 0) { _ in }
        try client.send(request, fd: ownedDescriptor)
        client.pump()

        let deadline = ContinuousClock.now + .seconds(2)
        var events: [WireMessage] = []
        while events.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
            client.pump()
            events = client.drainEvents()
        }
        #expect(WireMessage.first(
            events,
            object: controlID,
            opcode: 1) != nil)
        #expect(delegate.clearCount == 1)
    }
}
