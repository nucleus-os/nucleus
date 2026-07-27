import NucleusAndroidComposerProtocolC

struct ComposerOutputTopologyState {
    struct Output: Equatable {
        let name: String
        let displayID: UInt64
        let connected: Bool
        let width: Int32
        let height: Int32
        let refreshMillihertz: Int32
        let refreshPeriodNanoseconds: UInt64
        let generation: UInt64
    }

    struct Update: Equatable {
        let operation: nucleus_composer_operation
        let output: Output
    }

    private var outputByName: [String: Output] = [:]
    private var nextDisplayID: UInt64 = 0
    private(set) var generation: UInt64 = 0

    var connectedOutputs: [Output] {
        outputByName.values
            .filter(\.connected)
            .sorted { $0.displayID < $1.displayID }
    }

    mutating func publish(
        name: String,
        width: Int32,
        height: Int32,
        refreshMillihertz: Int32
    ) -> Update? {
        guard let period = composerRefreshPeriodNanoseconds(
            refreshMillihertz: refreshMillihertz)
        else { return nil }
        let previous = outputByName[name]
        if let previous,
           previous.connected,
           previous.width == width,
           previous.height == height,
           previous.refreshMillihertz == refreshMillihertz {
            return nil
        }
        let displayID: UInt64
        if let previous {
            displayID = previous.displayID
        } else {
            displayID = nextDisplayID
            nextDisplayID &+= 1
        }
        generation &+= 1
        let output = Output(
            name: name,
            displayID: displayID,
            connected: true,
            width: width,
            height: height,
            refreshMillihertz: refreshMillihertz,
            refreshPeriodNanoseconds: period,
            generation: generation)
        outputByName[name] = output
        return Update(
            operation: previous?.connected == true
                ? NUCLEUS_COMPOSER_OUTPUT_MODE_CHANGED
                : NUCLEUS_COMPOSER_OUTPUT_CONNECTED,
            output: output)
    }

    mutating func disconnect(name: String) -> Update? {
        guard let previous = outputByName[name], previous.connected else {
            return nil
        }
        generation &+= 1
        let output = Output(
            name: previous.name,
            displayID: previous.displayID,
            connected: false,
            width: previous.width,
            height: previous.height,
            refreshMillihertz: previous.refreshMillihertz,
            refreshPeriodNanoseconds: previous.refreshPeriodNanoseconds,
            generation: generation)
        outputByName[name] = output
        return Update(
            operation: NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED,
            output: output)
    }
}
