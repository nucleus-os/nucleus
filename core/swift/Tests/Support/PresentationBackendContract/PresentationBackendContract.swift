public protocol PresentationBackendContractState {
    var exposesOutput: Bool { get }
    var acceptsFrame: Bool { get }
    var resourceIsReusable: Bool { get }

    mutating func acquire()
    mutating func submit()
    mutating func completePresentation()
    mutating func replacePresentedResource()
    mutating func pause()
    mutating func resume()
    mutating func removeOutput()
}

public enum PresentationBackendContractFailure:
    String, Sendable, Equatable
{
    case missingInitialOutput
    case initialFrameBlocked
    case acquiredResourceStillReusable
    case acquireDidNotBlockSecondFrame
    case submittedResourceReusedBeforeCompletion
    case completionDidNotRestoreReadiness
    case replacementDidNotReleaseResource
    case pauseStillExposesOutput
    case pauseStillAcceptsFrame
    case resumeDidNotRestoreOutput
    case removalStillExposesOutput
    case removalStillAcceptsFrame
    case removalWasReversedByResume
}

/// The presentation lifecycle every process-local backend must implement,
/// independent of whether completion comes from a Wayland release timeline or
/// a KMS page flip.
public func validatePresentationBackendContract<
    State: PresentationBackendContractState
>(
    _ initial: State
) -> [PresentationBackendContractFailure] {
    var state = initial
    var failures: [PresentationBackendContractFailure] = []
    if !state.exposesOutput {
        failures.append(.missingInitialOutput)
    }
    if !state.acceptsFrame {
        failures.append(.initialFrameBlocked)
    }

    state.acquire()
    if state.resourceIsReusable {
        failures.append(.acquiredResourceStillReusable)
    }
    if state.acceptsFrame {
        failures.append(.acquireDidNotBlockSecondFrame)
    }
    state.submit()
    if state.resourceIsReusable {
        failures.append(.submittedResourceReusedBeforeCompletion)
    }
    state.completePresentation()
    if !state.acceptsFrame {
        failures.append(.completionDidNotRestoreReadiness)
    }
    state.replacePresentedResource()
    state.completePresentation()
    if !state.resourceIsReusable {
        failures.append(.replacementDidNotReleaseResource)
    }

    state.pause()
    if state.exposesOutput {
        failures.append(.pauseStillExposesOutput)
    }
    if state.acceptsFrame {
        failures.append(.pauseStillAcceptsFrame)
    }
    state.resume()
    if !state.exposesOutput {
        failures.append(.resumeDidNotRestoreOutput)
    }

    state.removeOutput()
    if state.exposesOutput {
        failures.append(.removalStillExposesOutput)
    }
    if state.acceptsFrame {
        failures.append(.removalStillAcceptsFrame)
    }
    state.resume()
    if state.exposesOutput {
        failures.append(.removalWasReversedByResume)
    }
    return failures
}
