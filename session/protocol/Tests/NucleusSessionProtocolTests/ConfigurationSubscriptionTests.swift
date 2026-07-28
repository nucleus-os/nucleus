import NucleusConfig
import NucleusSessionProtocol
import Testing

@Suite struct ConfigurationSubscriptionTests {
    @Test func snapshotEnvelopeRoundTripsDeterministically() throws {
        let epoch = ConfigurationServiceEpoch(high: 1, low: 2)
        let envelope = ConfigurationSubscriptionEnvelope(
            payload: ConfigurationPublication.snapshot(
                epoch: epoch,
                generation: ConfigurationGeneration(rawValue: 42),
                configuration: NucleusConfiguration.defaults
                    .renderServerProjection))
        let first = try ConfigurationSubscriptionCodec.encode(envelope)
        let second = try ConfigurationSubscriptionCodec.encode(envelope)

        #expect(first == second)
        #expect(
            try ConfigurationSubscriptionCodec.decode(
                ConfigurationPublication.self,
                from: first) == envelope)
    }

    @Test func subscriptionOperationsCarryExplicitRoleAndGeneration() throws {
        let epoch = ConfigurationServiceEpoch(high: 3, low: 4)
        let requests = [
            ConfigurationSubscriptionRequest.subscribe(as: .renderServer),
            .currentSnapshot,
            .acknowledge(
                epoch: epoch,
                generation: ConfigurationGeneration(rawValue: 9)),
            .reject(
                epoch: epoch,
                generation: ConfigurationGeneration(rawValue: 10),
                reason: "invalid output scale"),
            .validate(source: "{}"),
            .replace(source: "{}"),
            .export,
        ]

        for request in requests {
            let envelope = ConfigurationSubscriptionEnvelope(payload: request)
            let bytes = try ConfigurationSubscriptionCodec.encode(envelope)
            #expect(
                try ConfigurationSubscriptionCodec.decode(
                    ConfigurationSubscriptionRequest.self,
                    from: bytes) == envelope)
        }
    }
}
