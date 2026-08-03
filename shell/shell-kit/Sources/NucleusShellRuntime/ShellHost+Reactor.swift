import Glibc
import NucleusLinuxDBus
import NucleusLinuxReactor
import NucleusShellAuth
internal import NucleusShellServices
import NucleusShellSignalC
internal import NucleusUI
internal import NucleusWindowClientInput
import NucleusWindowClientPasteboard
import NucleusWindowClientRuntime
import WaylandClient

@MainActor
extension ShellHost {
    func makeReactorWaitPlan(
        displayFileDescriptor: Int32,
        displayNeedsWrite: Bool,
        nowNanoseconds: UInt64
    ) -> ShellReactorWaitPlan {
        if renderWorkDue, nextPresentationDeadlineNs == nil {
            nextPresentationDeadlineNs = nowNanoseconds
        }

        var deadlines = NucleusWindowClientDeadlineSet()
        deadlines.add(
            relativeNanoseconds:
                inputRouter?.nanosecondsUntilNextRepeat(nowNs: nowNanoseconds))
        deadlines.add(
            relativeNanoseconds:
                inputScene?.nanosecondsUntilToolTip(
                    atNanoseconds: nowNanoseconds))
        if let clockDeadline = nextClockUpdateNanoseconds {
            deadlines.add(
                relativeNanoseconds:
                    clockDeadline > nowNanoseconds
                    ? clockDeadline - nowNanoseconds
                    : 0)
        }
        if renderWorkDue, let presentationDeadline = nextPresentationDeadlineNs {
            deadlines.add(
                relativeNanoseconds:
                    presentationDeadline > nowNanoseconds
                    ? presentationDeadline - nowNanoseconds
                    : 0)
        }

        let authDescriptors = authenticator?.pollDescriptors ?? []
        let pasteboardDescriptors = pasteboardAdapter?.pollDescriptors ?? []
        let dragDescriptors = dragDropAdapter?.pollDescriptors ?? []
        var interests: [LinuxReactorInterest] = []
        interests.reserveCapacity(
            8 + pasteboardDescriptors.count + dragDescriptors.count)
        interests.append(
            LinuxReactorInterest(
                token: Self.reactorToken(.display),
                fileDescriptor: displayFileDescriptor,
                events: Int16(POLLIN)
                    | (displayNeedsWrite ? Int16(POLLOUT) : 0),
                mode: .multishot))
        interests.append(
            LinuxReactorInterest(
                token: Self.reactorToken(.exitSignal),
                fileDescriptor: exitSignalFD,
                events: Int16(POLLIN),
                mode: .multishot))
        interests.append(
            LinuxReactorInterest(
                token: Self.reactorToken(.renderWake),
                fileDescriptor: renderWake.fileDescriptor,
                events: Int16(POLLIN),
                mode: .multishot))
        if let configurationChannel {
            interests.append(
                LinuxReactorInterest(
                    token: Self.reactorToken(.configService),
                    fileDescriptor: configurationChannel.fileDescriptor,
                    events: Int16(POLLIN),
                    mode: .multishot))
        }
        if let policyChannel {
            interests.append(
                LinuxReactorInterest(
                    token: Self.reactorToken(.shellPolicy),
                    fileDescriptor: policyChannel.fileDescriptor,
                    events: Int16(POLLIN),
                    mode: .multishot))
        }
        for descriptor in authDescriptors {
            interests.append(
                LinuxReactorInterest(
                    token: Self.reactorToken(
                        descriptor.source == .response
                            ? .authenticationResponse
                            : .authenticationProcess),
                    fileDescriptor: descriptor.fileDescriptor,
                    events: Int16(POLLIN)))
        }
        deadlines.add(
            relativeNanoseconds:
                authenticator?.nanosecondsUntilDeadline(
                    nowNanoseconds: nowNanoseconds))
        if let systemBus {
            let fileDescriptor = systemBus.fileDescriptor
            let events = systemBus.pollEvents
            if NucleusWindowClientPollInterestPolicy.shouldRegister(
                fileDescriptor: fileDescriptor,
                events: events)
            {
                interests.append(
                    LinuxReactorInterest(
                        token: Self.reactorToken(.systemBus),
                        fileDescriptor: fileDescriptor,
                        events: events))
            }
            deadlines.add(
                relativeMicroseconds:
                    systemBus.timeoutMicroseconds())
        }
        appendLinuxReactorInterest(
            accessibilityAdapter,
            token: Self.reactorToken(.accessibility),
            interests: &interests,
            deadlines: &deadlines)
        appendLinuxReactorInterest(
            environmentAdapter,
            token: Self.reactorToken(.environment),
            interests: &interests,
            deadlines: &deadlines)
        for descriptor in pasteboardDescriptors {
            interests.append(
                LinuxReactorInterest(
                    token: Self.reactorToken(
                        .pasteboardTransfer,
                        instance: descriptor.token),
                    fileDescriptor: descriptor.fileDescriptor,
                    events: descriptor.events))
        }
        for descriptor in dragDescriptors {
            interests.append(
                LinuxReactorInterest(
                    token: Self.reactorToken(
                        .dragTransfer,
                        instance: descriptor.token),
                    fileDescriptor: descriptor.fileDescriptor,
                    events: descriptor.events))
        }
        deadlines.add(
            relativeNanoseconds:
                pasteboardAdapter?.nanosecondsUntilTransferDeadline(
                    nowNanoseconds: nowNanoseconds))
        deadlines.add(
            relativeNanoseconds:
                dragDropAdapter?.nanosecondsUntilTransferDeadline(
                    nowNanoseconds: nowNanoseconds))

        return ShellReactorWaitPlan(
            interests: interests,
            timeoutNanoseconds: deadlines.earliestNanoseconds)
    }

    func dispatchReactorBatch(
        _ batch: LinuxReactorBatch,
        preparedDisplayRead: WaylandPreparedRead,
        nowNanoseconds: UInt64
    ) -> ShellReactorBatchOutcome {
        var outcome = ShellReactorBatchOutcome()
        var displayReturnedEvents: Int16 = 0
        for event in batch.events
        where
            event.token >> Self.reactorKindShift == ReactorKind.display.rawValue
        {
            displayReturnedEvents |=
                event.failureCode == nil
                ? event.returnedEvents
                : Int16(POLLERR)
        }
        let displayResult = NucleusWindowClientPollResult(revents: displayReturnedEvents)

        let displayDispatch = preparedDisplayRead.complete(
            readable: displayResult.isReadable)
        if displayDispatch < 0 {
            client.markCompositorDisconnected()
            writeErr("nucleus-shell: Wayland dispatch failed")
            outcome.shouldStop = true
        } else if displayDispatch > 0 || displayResult.isReadable {
            outcome.hadHostEvent = true
            requestRender(nativeSceneChanged: true)
        }
        if displayResult.isTerminal {
            client.markCompositorDisconnected()
            writeErr("nucleus-shell: Wayland compositor disconnected")
            outcome.shouldStop = true
        } else if displayResult.isWritable {
            outcome.hadHostEvent = true
        }

        for event in batch.events {
            guard
                let kind = ReactorKind(
                    rawValue: event.token >> Self.reactorKindShift)
            else { continue }
            let instance = event.token & Self.reactorInstanceMask
            let result = NucleusWindowClientPollResult(
                revents: event.failureCode == nil
                    ? event.returnedEvents
                    : Int16(POLLERR))
            switch kind {
            case .display:
                continue
            case .exitSignal:
                if result.isTerminal || result.isReadable {
                    _ = nucleus_shell_consume_exit_signal(exitSignalFD)
                    outcome.shouldStop = true
                }
            case .renderWake:
                if result.isTerminal {
                    writeErr("nucleus-shell: renderer wake source failed")
                    outcome.shouldStop = true
                } else if result.isReadable, renderWake.drain() {
                    outcome.hadHostEvent = true
                    requestRender()
                }
            case .authenticationResponse, .authenticationProcess:
                if result.isInvalid || result.hasError {
                    authenticator?.failPendingAttempt(
                        "Authentication helper descriptor failed")
                    outcome.hadHostEvent = true
                    requestRender(nativeSceneChanged: true)
                } else if result.isReadable || result.isHungUp {
                    authenticator?.process(
                        kind == .authenticationResponse
                            ? .response
                            : .process,
                        nowNanoseconds: nowNanoseconds)
                    outcome.hadHostEvent = true
                    requestRender(nativeSceneChanged: true)
                }
            case .systemBus:
                outcome.processedSystemBus = true
                if result.isTerminal {
                    closeSystemBusIntegration(
                        reason: "system bus descriptor closed")
                } else if let systemBus {
                    do {
                        if try systemBus.process() {
                            requestRender(nativeSceneChanged: true)
                        }
                        outcome.hadHostEvent = true
                    } catch {
                        closeSystemBusIntegration(
                            reason: "system bus error: \(error)")
                    }
                }
            case .accessibility:
                outcome.processedAccessibility = true
                outcome.hadHostEvent =
                    processLinuxReactorSource(
                        accessibilityAdapter,
                        result: result,
                        failureOperation: "accessibility bus descriptor closed")
                    || outcome.hadHostEvent
            case .environment:
                outcome.processedEnvironment = true
                outcome.hadHostEvent =
                    processLinuxReactorSource(
                        environmentAdapter,
                        result: result,
                        failureOperation:
                            "desktop settings portal descriptor closed")
                    || outcome.hadHostEvent
            case .pasteboardTransfer:
                pasteboardAdapter?.processPollResult(
                    token: instance,
                    result: result,
                    nowNanoseconds: nowNanoseconds)
                outcome.hadHostEvent = true
            case .dragTransfer:
                dragDropAdapter?.processPollResult(
                    token: instance,
                    result: result,
                    nowNanoseconds: nowNanoseconds)
                outcome.hadHostEvent = true
            case .configService:
                if result.isTerminal {
                    writeErr(
                        "nucleus-shell: configuration service disconnected")
                    outcome.shouldStop = true
                } else if result.isReadable {
                    receiveConfigurationPublication()
                    outcome.hadHostEvent = true
                }
            case .shellPolicy:
                if result.isTerminal {
                    writeErr(
                        "nucleus-shell: shell policy channel disconnected")
                    outcome.shouldStop = true
                } else if result.isReadable {
                    receiveShellPolicyPublication()
                    outcome.hadHostEvent = true
                }
            }
            if outcome.shouldStop { break }
        }
        authenticator?.processDeadline(nowNanoseconds: nowNanoseconds)
        return outcome
    }

    func receiveShellPolicyPublication() {
        guard let policyChannel else { return }
        do {
            let publication =
                try policyChannel.receivePublication()
            if publication.kind == .ready {
                policyReady = true
                applyShellPolicyPreferences()
            }
            if actionDispatcher.receive(publication) {
                requestRender(nativeSceneChanged: true)
            }
        } catch {
            writeErr(
                "nucleus-shell: invalid shell policy publication: \(error)")
            running = false
        }
    }

    func processUnsignaledReactorSources(
        after outcome: ShellReactorBatchOutcome
    ) -> Bool {
        var hadHostEvent = outcome.hadHostEvent
        if !outcome.processedSystemBus,
            let systemBus,
            systemBus.timeoutMicroseconds() == 0
        {
            do {
                if try systemBus.process() {
                    requestRender(nativeSceneChanged: true)
                }
                hadHostEvent = true
            } catch {
                closeSystemBusIntegration(
                    reason: "system bus error: \(error)")
            }
        }
        if !outcome.processedAccessibility {
            hadHostEvent =
                processLinuxReactorSource(
                    accessibilityAdapter,
                    result: nil,
                    failureOperation: "accessibility bus descriptor closed")
                || hadHostEvent
        }
        if !outcome.processedEnvironment {
            hadHostEvent =
                processLinuxReactorSource(
                    environmentAdapter,
                    result: nil,
                    failureOperation:
                        "desktop settings portal descriptor closed")
                || hadHostEvent
        }
        return hadHostEvent
    }

    func closeSystemBusIntegration(reason: String) {
        writeErr("nucleus-shell: \(reason)")
        upower?.stop()
        upower = nil
        systemBus?.close()
        systemBus = nil
    }

    func appendLinuxReactorInterest<Source: LinuxReactorSource>(
        _ source: Source?,
        token: UInt64,
        interests: inout [LinuxReactorInterest],
        deadlines: inout NucleusWindowClientDeadlineSet
    ) {
        guard let source else { return }
        deadlines.add(relativeMicroseconds: source.timeoutMicroseconds())
        let fileDescriptor = source.fileDescriptor
        let events = source.pollEvents
        guard
            NucleusWindowClientPollInterestPolicy.shouldRegister(
                fileDescriptor: fileDescriptor,
                events: events)
        else {
            return
        }
        interests.append(
            LinuxReactorInterest(
                token: token,
                fileDescriptor: fileDescriptor,
                events: events))
    }

    func processLinuxReactorSource<Source: LinuxReactorSource>(
        _ source: Source?,
        result: NucleusWindowClientPollResult?,
        failureOperation: String
    ) -> Bool {
        guard let source else { return false }
        if result?.isTerminal == true {
            source.transportDidFail(operation: failureOperation)
            return true
        }
        guard
            (result?.revents ?? 0) != 0
                || source.timeoutMicroseconds() == 0
        else { return false }
        if source.process() {
            requestRender(nativeSceneChanged: true)
        }
        return true
    }
}
