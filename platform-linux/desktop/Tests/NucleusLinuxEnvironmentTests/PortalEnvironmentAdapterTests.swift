import NucleusLinuxDBus
import NucleusUI
import Synchronization
@testable import NucleusLinuxEnvironment
import Testing

@MainActor
@Suite struct PortalEnvironmentAdapterTests {
    private final class Clock: Sendable {
        private let storage: Mutex<UInt64>

        var now: UInt64 {
            get { storage.withLock { $0 } }
            set { storage.withLock { $0 = newValue } }
        }

        init(now: UInt64) {
            storage = Mutex(now)
        }
    }

    @Test func normalizationProducesOnePortableSnapshot() {
        let environment = PortalEnvironmentSettings(
            colorScheme: 2,
            contrast: 1,
            reducesMotion: nil,
            animationsEnabled: false,
            reducesTransparency: true,
            textScale: 9
        ).normalized()

        #expect(environment == UIEnvironment(
            reducesMotion: true,
            reducesTransparency: true,
            increasesContrast: true,
            appearance: .light,
            textScale: 4))
    }

    @Test func missingValuesPreserveTheLastNormalizedSnapshot() {
        let previous = UIEnvironment(
            reducesMotion: true,
            reducesTransparency: true,
            increasesContrast: true,
            appearance: .light,
            textScale: 1.75)

        #expect(PortalEnvironmentSettings().normalized(
            fallback: previous) == previous)
    }

    @Test func invalidPortalEnumsAndScaleCanonicalizeOnce() {
        let environment = PortalEnvironmentSettings(
            colorScheme: 99,
            contrast: 99,
            textScale: .nan
        ).normalized()

        #expect(environment.appearance == .dark)
        #expect(!environment.increasesContrast)
        #expect(environment.textScale == 1)
    }

    @Test func reconnectBackoffDoesNotDuplicateAttemptsAfterStop() {
        let clock = Clock(now: 1_000_000_000)
        var attempts = 0
        let adapter = PortalEnvironmentAdapter(
            connectionFactory: {
                () throws(DBusError) -> DBusConnection in
                attempts += 1
                throw DBusError(
                    name: "org.test.Unavailable",
                    message: "fixture")
            },
            nowNanoseconds: { clock.now })

        _ = adapter.start()
        #expect(attempts == 1)
        #expect(adapter.timeoutMicroseconds() == 100_000)

        clock.now += 99_000_000
        #expect(!adapter.process())
        #expect(attempts == 1)

        clock.now += 1_000_000
        #expect(!adapter.process())
        #expect(attempts == 2)
        #expect(adapter.timeoutMicroseconds() == 200_000)

        adapter.stop()
        clock.now += 1_000_000_000
        #expect(!adapter.process())
        #expect(attempts == 2)
        #expect(adapter.timeoutMicroseconds() == nil)
        #expect(!adapter.hasSubscription)
    }
}
