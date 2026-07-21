public struct FoundationWorkCounters: Sendable, Equatable {
    public var visits: UInt64
    public var commits: UInt64
    public var registrations: UInt64
    public var acquisitions: UInt64
    public var presentations: UInt64
    public var liveResources: UInt64

    public init(
        visits: UInt64 = 0,
        commits: UInt64 = 0,
        registrations: UInt64 = 0,
        acquisitions: UInt64 = 0,
        presentations: UInt64 = 0,
        liveResources: UInt64 = 0
    ) {
        self.visits = visits
        self.commits = commits
        self.registrations = registrations
        self.acquisitions = acquisitions
        self.presentations = presentations
        self.liveResources = liveResources
    }

    public func delta(
        from baseline: FoundationWorkCounters
    ) -> FoundationWorkCounters {
        FoundationWorkCounters(
            visits: visits &- baseline.visits,
            commits: commits &- baseline.commits,
            registrations: registrations &- baseline.registrations,
            acquisitions: acquisitions &- baseline.acquisitions,
            presentations: presentations &- baseline.presentations,
            liveResources: liveResources &- baseline.liveResources)
    }

    public var performsNoWork: Bool {
        visits == 0
            && commits == 0
            && registrations == 0
            && acquisitions == 0
            && presentations == 0
    }
}
