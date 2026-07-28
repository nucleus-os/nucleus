import NucleusControlProtocol
import NucleusControlService
import NucleusSessionProtocol
import Testing

@Suite struct ControlRoutingTests {
    @Test func unavailableOwnersProduceStableTypedFailure() {
        let route = ControlRouting.route(
            .outputs,
            configurationAvailability: .init(available: true),
            renderServerAvailability: .init(available: false),
            hasElevatedCapability: false)
        #expect(route == .local(.error(ControlFailure(
            code: .ownerUnavailable,
            message: "request owner is unavailable"))))
    }

    @Test func configurationMutationRequiresCapability() {
        #expect(ControlRouting.route(
            .replaceConfiguration("{}"),
            configurationAvailability: .init(available: true),
            renderServerAvailability: .init(available: true),
            hasElevatedCapability: false) == .unauthorized)
        #expect(ControlRouting.route(
            .replaceConfiguration("{}"),
            configurationAvailability: .init(available: true),
            renderServerAvailability: .init(available: true),
            hasElevatedCapability: true)
            == .configuration(.replace(source: "{}")))
    }

    @Test func actionsRouteOnlyToTheRenderOwner() {
        #expect(ControlRouting.route(
            .action(.closeWindow),
            configurationAvailability: .init(available: true),
            renderServerAvailability: .init(available: true),
            hasElevatedCapability: false)
            == .renderServer(.action(.closeWindow)))
    }

    @Test func ownerFailuresMapToStablePublicCodes() {
        let expected: [(OwnerControlFailureCode, ControlErrorCode)] = [
            (.unavailable, .ownerUnavailable),
            (.staleGeneration, .staleGeneration),
            (.unauthorized, .unauthorized),
            (.invalidRequest, .invalidRequest),
            (.rejected, .rejected),
            (.internalTransport, .internalTransport),
        ]
        for (owner, publicCode) in expected {
            #expect(ControlRouting.failure(
                code: owner,
                message: "fixture").code == publicCode)
        }
    }
}
