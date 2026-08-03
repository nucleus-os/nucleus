import Glibc
import NucleusShellAuth
import NucleusShellAuthWire
import NucleusShellProduct
import NucleusUI
import Testing

@Suite(.serialized)
@MainActor
struct PamAuthenticatorTests {
    private final class OutcomeBox {
        var value: LockAuthenticationOutcome?
    }

    @Test func responseAndExitOrdersCompleteExactlyOnce() {
        #expect(run(service: "accepted") == .accepted)
        #expect(unavailable(run(service: "exit-first")))
        #expect(unavailable(run(service: "partial")))
        #expect(unavailable(run(service: "oversized")))
        #expect(unavailable(run(service: "malformed")))
        #expect(unavailable(run(service: "crash")))
    }

    @Test func aSilentHelperHitsTheWholeAttemptDeadline() {
        let result = run(
            service: "silent",
            attemptTimeout: 5_000_000,
            exitGrace: 100_000_000)
        #expect(unavailable(result))
    }

    @Test func maximumRequestIsFramedOnceAndScrubbedInPlace() {
        let service = [UInt8](
            repeating: 0x73,
            count: PamHelperWire.maximumServiceBytes)
        let password = [UInt8](
            repeating: 0x70,
            count: PamHelperWire.maximumPasswordBytes)
        var request: PamCredentialRequest?
        password.withUnsafeBytes {
            request = unsafe PamCredentialRequest(
                service: service,
                password: $0)
        }
        guard var request = consume request else {
            Issue.record("maximum valid request was rejected")
            return
        }
        let capacity = request.storage.capacity
        #expect(
            request.storage.count
                == 8 + service.count + password.count)
        request.scrub()
        #expect(request.storage.capacity == capacity)
        #expect(request.storage.allSatisfy { $0 == 0 })
    }

    @Test func aVerdictFromALingeringHelperHitsExitGraceAndIsReaped() {
        let start = monotonicNow()
        let result = run(
            service: "linger",
            attemptTimeout: 500_000_000,
            exitGrace: 5_000_000)
        #expect(unavailable(result))
        #expect(monotonicNow() - start < 400_000_000)
    }

    @Test func pidfdSetupFailureFailsClosedWithoutBlocking() {
        let outcome = OutcomeBox()
        let authenticator = PamAuthenticator(
            helperPath: fixturePath(),
            pidFDOpen: { _ in -1 })
        authenticator.service = "linger"
        let start = monotonicNow()
        authenticator.authenticate(password: SecureBytes(utf8: "secret")) {
            outcome.value = $0
        }
        #expect(monotonicNow() - start < 100_000_000)
        #expect(outcome.value.map(unavailable) == true)
        #expect(authenticator.pollDescriptors.isEmpty)
    }

    @Test func cancellationKillsAndReapsThroughThePidfd() {
        let outcome = OutcomeBox()
        var completionCount = 0
        let authenticator = PamAuthenticator(helperPath: fixturePath())
        authenticator.service = "linger"
        authenticator.authenticate(password: SecureBytes(utf8: "secret")) {
            completionCount += 1
            outcome.value = $0
        }
        authenticator.cancelPendingAttempt()
        drive(authenticator, until: outcome)
        #expect(outcome.value.map(unavailable) == true)
        #expect(completionCount == 1)
    }

    private func run(
        service: String,
        attemptTimeout: UInt64 = 250_000_000,
        exitGrace: UInt64 = 25_000_000
    ) -> LockAuthenticationOutcome {
        let outcome = OutcomeBox()
        var completionCount = 0
        let authenticator = PamAuthenticator(
            helperPath: fixturePath(),
            attemptTimeoutNanoseconds: attemptTimeout,
            exitGraceNanoseconds: exitGrace)
        authenticator.service = service
        authenticator.authenticate(
            password: SecureBytes(utf8: "secret")
        ) {
            completionCount += 1
            outcome.value = $0
        }

        drive(authenticator, until: outcome)
        #expect(completionCount == 1)
        return outcome.value ?? .unavailable("fixture timed out")
    }

    private func drive(
        _ authenticator: PamAuthenticator,
        until outcome: OutcomeBox
    ) {
        let outerDeadline = monotonicNow() + 1_000_000_000
        while outcome.value == nil, monotonicNow() < outerDeadline {
            let descriptors = authenticator.pollDescriptors
            var pollDescriptors = descriptors.map {
                pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0)
            }
            _ = unsafe poll(
                &pollDescriptors,
                nfds_t(pollDescriptors.count),
                5)
            let now = monotonicNow()
            for (index, descriptor) in descriptors.enumerated()
            where pollDescriptors[index].revents != 0 {
                authenticator.process(
                    descriptor.source,
                    nowNanoseconds: now)
            }
            authenticator.processDeadline(nowNanoseconds: now)
        }
    }

    private func unavailable(_ outcome: LockAuthenticationOutcome) -> Bool {
        if case .unavailable = outcome { return true }
        return false
    }

    private func fixturePath() -> String {
        let executable = CommandLine.arguments[0]
        let directory = String(
            executable[..<executable.lastIndex(of: "/")!])
        let candidates = [
            "\(directory)/NucleusShellPamAttemptFixture",
            "\(directory)/../NucleusShellPamAttemptFixture",
        ]
        return candidates.first { unsafe access($0, X_OK) == 0 }
            ?? candidates[0]
    }

    private func monotonicNow() -> UInt64 {
        var value = timespec(tv_sec: 0, tv_nsec: 0)
        unsafe clock_gettime(CLOCK_MONOTONIC, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}
