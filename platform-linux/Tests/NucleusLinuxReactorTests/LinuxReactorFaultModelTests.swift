import Glibc
import Testing
@testable import NucleusLinuxReactor

@Suite(.serialized)
struct LinuxReactorFaultModelTests {
    @MainActor
    @Test
    func timerProgrammingFailureIsTypedAndTerminal() async throws {
        let expected = LinuxHostReactorError.system(
            operation: "programming reactor timer", code: -EIO)
        let reactor = try LinuxHostReactor(
            queueDepth: 16,
            completionBudget: 16,
            faultPlan: LinuxReactorFaultPlan(
                failures: [.programTimer: [1: -EIO]]))

        await expectFailure(expected) {
            try await reactor.wait(
                interests: [], timeoutNanoseconds: 1_000_000)
        }
        await expectFailure(expected) {
            try await reactor.wait(
                interests: [], timeoutNanoseconds: nil)
        }
        await reactor.shutdown()
    }

    @MainActor
    @Test
    func submissionFailureIsTypedAndTerminal() async throws {
        let expected = LinuxHostReactorError.system(
            operation: "submitting io_uring requests", code: -EIO)
        let reactor = try LinuxHostReactor(
            queueDepth: 16,
            completionBudget: 16,
            faultPlan: LinuxReactorFaultPlan(
                failures: [.submit: [1: -EIO]]))

        await expectFailure(expected) {
            try await reactor.wait(
                interests: [], timeoutNanoseconds: nil)
        }
        #expect(reactor.metrics.submissionCalls == 0)
        #expect(reactor.metrics.requestsSubmitted == 0)
        await reactor.shutdown()
    }

    @MainActor
    @Test
    func repeatedPollPreparationExhaustionFailsWithoutSuspending() async throws {
        let expected = LinuxHostReactorError.system(
            operation: "preparing io_uring poll", code: -ENOSPC)
        let reactor = try LinuxHostReactor(
            queueDepth: 16,
            completionBudget: 16,
            faultPlan: LinuxReactorFaultPlan(
                failures: [.preparePoll: [1: -ENOSPC, 2: -ENOSPC]]))

        await expectFailure(expected) {
            try await reactor.wait(
                interests: [.init(
                    token: 1,
                    fileDescriptor: STDIN_FILENO,
                    events: Int16(POLLIN))],
                timeoutNanoseconds: nil)
        }
        #expect(reactor.metrics.activeContexts == 0)
        await reactor.shutdown()
    }

    @MainActor
    @Test
    func oneFullSubmissionQueueRetriesThePreparation() async throws {
        let reactor = try LinuxHostReactor(
            queueDepth: 16,
            completionBudget: 16,
            faultPlan: LinuxReactorFaultPlan(
                failures: [.preparePoll: [1: -ENOSPC]]))
        reactor.wake()

        let batch = try await reactor.wait(
            interests: [], timeoutNanoseconds: 1_000_000_000)
        #expect(batch.wasExplicitlyWoken)
        #expect(reactor.metrics.activeContexts == 2)
        await reactor.shutdown()
    }

    @MainActor
    @Test
    func repeatedCancellationPreparationExhaustionIsTerminal() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(pipe(&descriptors) == 0)
        defer {
            for descriptor in descriptors { _ = Glibc.close(descriptor) }
        }
        let reactor = try LinuxHostReactor(
            queueDepth: 16,
            completionBudget: 16,
            faultPlan: LinuxReactorFaultPlan(failures: [
                .prepareCancellation: [1: -ENOSPC, 2: -ENOSPC],
            ]))
        reactor.wake()
        _ = try await reactor.wait(
            interests: [.init(
                token: 9,
                fileDescriptor: descriptors[0],
                events: Int16(POLLIN))],
            timeoutNanoseconds: nil)

        await expectFailure(.system(
            operation: "preparing io_uring poll cancellation",
            code: -ENOSPC)) {
            try await reactor.wait(
                interests: [], timeoutNanoseconds: nil)
        }
        await reactor.shutdown()
    }

    @Test
    func completionLedgerMatchesIndependentReferenceModel() {
        var generator = DeterministicGenerator(state: 0x4e55_434c_4555_5301)
        var ledger = LinuxReactorContextLedger()
        var registrations: [UInt64: LinuxReactorRegistrationRecord] = [:]
        var referenceContextToToken: [UInt64: UInt64] = [:]
        var referenceCurrentContext: [UInt64: UInt64] = [:]
        var nextContext: UInt64 = 1

        for step in 0..<5_000 {
            let action = generator.next() % 5
            if action <= 1 {
                let token = (generator.next() % 32) + 1
                let context = nextContext
                nextContext += 1
                registrations[token] = LinuxReactorRegistrationRecord(
                    fileDescriptor: Int32(token),
                    events: Int16(POLLIN),
                    mode: generator.next() & 1 == 0 ? .oneShot : .multishot,
                    context: context)
                ledger.bind(context: context, to: token)
                referenceContextToToken[context] = token
                referenceCurrentContext[token] = context
            } else if action == 2 {
                let token = (generator.next() % 32) + 1
                registrations.removeValue(forKey: token)
                referenceCurrentContext.removeValue(forKey: token)
            } else {
                let knownContexts = referenceContextToToken.keys.sorted()
                let selection = generator.next() % 4
                let context: UInt64
                if selection == 0 {
                    context = 0
                } else if selection <= 2, !knownContexts.isEmpty {
                    context = knownContexts[
                        Int(generator.next() % UInt64(knownContexts.count))]
                } else {
                    context = nextContext + 10_000 + generator.next() % 1_000
                }
                let result: Int32
                switch generator.next() % 4 {
                case 0: result = -ECANCELED
                case 1: result = -EIO
                default: result = Int32(POLLIN)
                }
                let completion = LinuxReactorCompletionSnapshot(
                    context: context,
                    result: result,
                    willContinue: generator.next() & 1 == 0)

                let expected = referenceResolution(
                    completion,
                    contextToToken: &referenceContextToToken,
                    currentContext: &referenceCurrentContext)
                let actual = ledger.resolve(
                    completion, registrations: &registrations)
                guard actual == expected else {
                    Issue.record("model mismatch at step \(step)")
                    return
                }
                guard ledger.count == referenceContextToToken.count else {
                    Issue.record("context leak at step \(step)")
                    return
                }
                for (token, context) in referenceCurrentContext {
                    guard registrations[token]?.context == context else {
                        Issue.record(
                            "registration mismatch for token \(token) at step \(step)")
                        return
                    }
                }
            }
        }
    }

    @MainActor
    private func expectFailure(
        _ expected: LinuxHostReactorError,
        operation: () async throws -> LinuxReactorBatch
    ) async {
        do {
            _ = try await operation()
            Issue.record("reactor operation unexpectedly succeeded")
        } catch let error as LinuxHostReactorError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected reactor error: \(error)")
        }
    }

    private func referenceResolution(
        _ completion: LinuxReactorCompletionSnapshot,
        contextToToken: inout [UInt64: UInt64],
        currentContext: inout [UInt64: UInt64]
    ) -> LinuxReactorCompletionResolution {
        guard completion.context != 0 else { return .cancellation }
        guard let token = contextToToken[completion.context] else {
            return .stale
        }
        if !completion.willContinue {
            contextToToken.removeValue(forKey: completion.context)
        }
        guard currentContext[token] == completion.context else {
            return completion.result == -ECANCELED ? .cancellation : .stale
        }
        if !completion.willContinue {
            currentContext.removeValue(forKey: token)
        }
        if completion.result == -ECANCELED { return .cancellation }
        return .active(token: token, result: completion.result)
    }
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
