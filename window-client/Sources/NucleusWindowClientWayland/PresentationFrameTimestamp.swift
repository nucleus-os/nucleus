struct NucleusPresentationFrameTimestamp {
    private var previousProtocolMilliseconds: UInt32?
    private var previousMonotonicNanoseconds: UInt64?

    mutating func resolve(
        protocolMilliseconds: UInt32,
        observedMonotonicNanoseconds: UInt64
    ) -> UInt64 {
        guard let previousProtocolMilliseconds,
            let previousMonotonicNanoseconds
        else {
            self.previousProtocolMilliseconds = protocolMilliseconds
            self.previousMonotonicNanoseconds = observedMonotonicNanoseconds
            return observedMonotonicNanoseconds
        }

        let wrappedDelta = protocolMilliseconds &- previousProtocolMilliseconds
        let forwardMilliseconds =
            wrappedDelta <= UInt32.max / 2 ? UInt64(wrappedDelta) : 0
        let (advanced, overflow) =
            previousMonotonicNanoseconds
            .addingReportingOverflow(forwardMilliseconds * 1_000_000)
        let resolved = overflow ? UInt64.max : advanced
        self.previousProtocolMilliseconds = protocolMilliseconds
        self.previousMonotonicNanoseconds = resolved
        return resolved
    }
}
