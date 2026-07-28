import FoundationEssentials
import NucleusConfig
import NucleusFoundation
import Testing
@testable import NucleusControlProtocol

@Suite struct ControlProtocolTests {
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try ControlCoding.encoder().encode(request)
        return try ControlCoding.decoder().decode(
            ControlRequest.self, from: data)
    }

    private func roundTrip(
        _ response: ControlResponse
    ) throws -> ControlResponse {
        let data = try ControlCoding.encoder().encode(response)
        return try ControlCoding.decoder().decode(
            ControlResponse.self, from: data)
    }

    // MARK: requests

    @Test func everyRequestRoundTrips() throws {
        let requests: [ControlRequest] = [
            .version, .configuration, .reloadConfiguration, .outputs, .binds,
            .validateConfiguration("{}"),
            .replaceConfiguration("{\"config_version\":1}"),
            .exportConfiguration,
            .action(.closeWindow),
            .action(.activateWorkspace(3)),
            .action(.tile(.bottomRight)),
            .action(.launch(appIDs: ["kitty.desktop"], command: ["kitty"])),
        ]
        for request in requests {
            #expect(try roundTrip(request) == request, "\(request)")
        }
    }

    @Test func anUnknownRequestIsRejectedByName() throws {
        let data = Data(#"{"request":"self-destruct"}"#.utf8)
        #expect(throws: (any Error).self) {
            try ControlCoding.decoder().decode(ControlRequest.self, from: data)
        }
    }

    @Test func actionRequestsCarryTheSharedBindVocabulary() throws {
        // The point of reusing BindAction: a request and a keybinding describe
        // the same operation with the same type.
        let request = ControlRequest.action(.moveWindowToWorkspace(7))
        guard case .action(let action) = try roundTrip(request) else {
            Issue.record("expected an action request")
            return
        }
        #expect(action == .moveWindowToWorkspace(7))
    }

    // MARK: responses

    @Test func everyResponseRoundTrips() throws {
        let responses: [ControlResponse] = [
            .accepted,
            .completed,
            .version(ControlVersionInfo(
                configurationService: .init(available: true),
                renderServer: .init(
                    available: true, version: "nucleus-render-server 1"))),
            .configuration(ControlConfigurationSnapshot(
                canonicalSource: "{\"config_version\":1}",
                configuredEpochHigh: 1,
                configuredEpochLow: 2,
                configuredGeneration: 3,
                renderServerAppliedGeneration: 3)),
            .validation([]),
            .binds(ControlBindingSnapshot(
                binds: DefaultBinds.table,
                appliedConfigurationGeneration: 3)),
            .outputs(ControlOutputSnapshot(
                outputs: [ControlOutput(
                    id: OutputID(rawValue: 1),
                    name: "DP-1", width: 2560, height: 1440,
                    refreshMillihertz: 143_998, scale: 1.5,
                    x: 0, y: 0, enabled: true)],
                appliedConfigurationGeneration: 3)),
            .error(ControlFailure(
                code: .rejected,
                message: "no focused window")),
        ]
        for response in responses {
            #expect(try roundTrip(response) == response, "\(response)")
        }
    }

    @Test func refreshRateSurvivesAsMillihertz() throws {
        // 59.94 Hz is 59940 mHz; rounding to integer hertz would lose it, and
        // the whole reason the field is millihertz is to keep it.
        let output = ControlOutput(
            id: OutputID(rawValue: 2),
            name: "HDMI-A-1", width: 1920, height: 1080,
            refreshMillihertz: 59_940, scale: 1, x: 0, y: 0, enabled: true)
        guard case .outputs(let decoded) = try roundTrip(.outputs(
            ControlOutputSnapshot(
                outputs: [output],
                appliedConfigurationGeneration: 5)))
        else {
            Issue.record("expected outputs")
            return
        }
        #expect(decoded.outputs.first?.refreshMillihertz == 59_940)
        #expect(decoded.appliedConfigurationGeneration == 5)
    }

    @Test func aConfigurationResponseUsesTheFileSpelling() throws {
        // Keys match config.json so a response can be pasted back into it.
        let data = try ControlCoding.encoder().encode(
            ControlResponse.configuration(ControlConfigurationSnapshot(
                canonicalSource: "{\"config_version\":1,\"input\":{\"natural_scroll\":true}}",
                configuredEpochHigh: 1,
                configuredEpochLow: 2,
                configuredGeneration: 3,
                renderServerAppliedGeneration: 3)))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("config_version"))
        #expect(text.contains("natural_scroll"))
        #expect(!text.contains("\"naturalScroll\""))
    }

    // MARK: envelopes and packet coding

    @Test func requestEnvelopeRoundTripsVersionAndCorrelationID() throws {
        let envelope = ControlRequestEnvelope(
            requestID: ControlRequestID(rawValue: 42),
            request: .version)
        let packet = try ControlCoding.packet(envelope)
        let decoded = try ControlCoding.decoder().decode(
            ControlRequestEnvelope.self,
            from: Data(packet))
        #expect(decoded == envelope)
        #expect(decoded.protocolVersion == ControlProtocolVersion.current)
    }

    @Test func packetCodingIsDeterministic() throws {
        let envelope = ControlResponseEnvelope(
            requestID: ControlRequestID(rawValue: 7),
            response: .binds(ControlBindingSnapshot(
                binds: DefaultBinds.table,
                appliedConfigurationGeneration: 7)))
        #expect(
            try ControlCoding.packet(envelope)
                == ControlCoding.packet(envelope))
    }
}
