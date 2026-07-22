import Testing
@testable import NucleusUI

@MainActor
@Suite struct UIClockTests {
    @Test func deadlineAdvancementIsExactAndResumesEveryWaiter() async throws {
        let manual = ManualUIClock()
        let clock = manual.clock
        var resumed: [Int] = []
        let first = Task { @MainActor in
            try await clock.sleep(for: .milliseconds(700))
            resumed.append(1)
        }
        let second = Task { @MainActor in
            try await clock.sleep(for: .milliseconds(700))
            resumed.append(2)
        }
        await waitForWaiters(2, on: manual)

        manual.advance(by: .nanoseconds(699_999_999))
        await Task.yield()
        #expect(resumed.isEmpty)
        #expect(manual.waiterCount == 2)

        manual.advance(by: .nanoseconds(1))
        try await first.value
        try await second.value
        #expect(resumed.sorted() == [1, 2])
        #expect(manual.waiterCount == 0)
    }

    @Test func cancellationRemovesAWaiterExactlyOnce() async {
        let manual = ManualUIClock()
        let clock = manual.clock
        var reachedDeadline = false
        let task = Task { @MainActor in
            do {
                try await clock.sleep(for: .seconds(1))
                reachedDeadline = true
            } catch is CancellationError {
                return
            } catch {
                Issue.record("unexpected clock error: \(error)")
            }
        }
        await waitForWaiters(1, on: manual)
        task.cancel()
        for _ in 0..<32 where manual.waiterCount != 0 {
            await Task.yield()
        }
        #expect(manual.waiterCount == 0)

        manual.advance(by: .seconds(2))
        await task.value
        #expect(!reachedDeadline)
        #expect(manual.waiterCount == 0)
    }

    @Test func durationConversionAndDeadlineAdditionSaturate() {
        #expect(UIClock.saturatingNanoseconds(.nanoseconds(-1)) == 0)
        #expect(UIClock.saturatingNanoseconds(.milliseconds(700)) == 700_000_000)
        #expect(UIClock.Instant(rawValue: .max - 1).advanced(
            by: .nanoseconds(2)).rawValue == .max)
    }

    private func waitForWaiters(
        _ count: Int,
        on clock: ManualUIClock
    ) async {
        for _ in 0..<32 where clock.waiterCount != count {
            await Task.yield()
        }
        #expect(clock.waiterCount == count)
    }
}
