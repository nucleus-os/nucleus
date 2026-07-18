import Testing
import NucleusUI
import NucleusCompositorOverlayTypes
import NucleusUIEmbedder
@_spi(NucleusCompositor) import NucleusLayers
@testable import NucleusCompositorOverlay

/// The compositor's keyboard adapter: composed text, modifier flags, and key
/// repeat. These are the pieces Phase 8 left deferred and text input needs.
@MainActor
@Suite struct ShellOverlayKeyboardTests {
    private static func keyEvent(
        _ kind: ShellOverlayInputKind,
        keycode: UInt32,
        modifiers: UInt32 = 0,
        text: String? = nil,
        timestampNs: UInt64 = 0
    ) -> ShellOverlayInputEvent {
        ShellOverlayInputEvent(NucleusCompositorOverlayTypes.InputEvent(
            kind: NucleusCompositorOverlayTypes.InputKind(rawValue: kind.rawValue) ?? .keyDown,
            button: 0, x: 0, y: 0, scrollX: 0, scrollY: 0,
            keycode: keycode, modifiers: modifiers, text: text, timestampNs: timestampNs))
    }

    // MARK: - Composed text

    /// Text reaches the framework event as `characters`, carried alongside the
    /// keycode rather than derived from it — a keycode cannot express what a
    /// layout, dead key, or compose sequence produced.
    @Test func composedTextReachesTheFrameworkEvent() throws {
        // KEY_A (30) under a layout that produced "ä".
        let event = Self.keyEvent(.keyDown, keycode: 30, text: "ä")
        let nucleon = try #require(event.nucleonEvent)

        #expect(nucleon.type == .keyDown)
        #expect(nucleon.characters == "ä")
    }

    @Test func aKeyWithNoTextCarriesNoCharacters() throws {
        // KEY_LEFT (105) produces no text.
        let event = Self.keyEvent(.keyDown, keycode: 105)
        let nucleon = try #require(event.nucleonEvent)

        #expect(nucleon.keyCode == .leftArrow)
        #expect(nucleon.characters == nil)
    }

    /// The wire event used to hardcode `text = nil`, so composed text was
    /// threaded through the type but never populated.
    @Test func theWireEventCarriesTextThrough() {
        let wire = NucleusCompositorOverlayTypes.InputEvent(
            kind: .keyDown, keycode: 30, text: "é")
        #expect(ShellOverlayInputEvent(wire).text == "é")
    }

    // MARK: - Modifiers

    /// The overlay key path passed `modifiers: 0` unconditionally, so shift,
    /// control, and command never reached a view.
    @Test func modifierBitsBecomeFrameworkFlags() throws {
        let shiftAndCommand: UInt32 = (1 << 17) | (1 << 20)
        let event = Self.keyEvent(.keyDown, keycode: 30, modifiers: shiftAndCommand, text: "A")
        let nucleon = try #require(event.nucleonEvent)

        #expect(nucleon.modifierFlags.contains(.shift))
        #expect(nucleon.modifierFlags.contains(.command))
        #expect(!nucleon.modifierFlags.contains(.control))
    }

    @Test func everyModifierBitIsMapped() throws {
        let all: UInt32 = (1 << 16) | (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        let nucleon = try #require(
            Self.keyEvent(.keyDown, keycode: 30, modifiers: all).nucleonEvent)

        #expect(nucleon.modifierFlags.contains(.capsLock))
        #expect(nucleon.modifierFlags.contains(.shift))
        #expect(nucleon.modifierFlags.contains(.control))
        #expect(nucleon.modifierFlags.contains(.option))
        #expect(nucleon.modifierFlags.contains(.command))
    }

    // MARK: - Key repeat

    /// A settable clock, so repeat timing is exercised against controlled time
    /// rather than whatever the monotonic clock happens to read.
    @MainActor final class TestClock {
        var nowNs: UInt64 = 0
    }

    private func makeScene(_ clock: TestClock) throws -> ShellOverlayScene {
        try ShellOverlayScene(
            frame: nil,
            nowNs: { clock.nowNs },
            commitSink: InMemoryCommitSink())
    }

    /// A held key produces no repeat until the delay elapses, then repeats at
    /// the same rate the compositor advertises to Wayland clients.
    @Test func aHeldKeyRepeatsAfterTheDelay() throws {
        final class CountingView: View {
            var repeats = 0
            var presses = 0
            override var acceptsFirstResponder: Bool { true }
            override func handleEvent(_ event: Event) -> EventHandling {
                guard event.type == .keyDown else { return .notHandled }
                if event.isARepeat { repeats += 1 } else { presses += 1 }
                return .handled
            }
        }

        let clock = TestClock()
        let scene = try makeScene(clock)
        let view = CountingView()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Repeat")
        window.setContentView(view)
        window.orderFront()
        scene.windowScene.addWindow(window)
        scene.windowScene.makeKey(window)
        #expect(window.makeFirstResponder(view))

        // KEY_LEFT down.
        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 105))
        #expect(scene.keyRepeatActive)

        // Before the 600 ms delay: nothing.
        #expect(!scene.advanceKeyRepeat(nowNs: 100_000_000))
        #expect(view.repeats == 0)

        // After it: one repeat, marked as such.
        #expect(scene.advanceKeyRepeat(nowNs: 620_000_000))
        #expect(view.repeats >= 1)
        let afterFirst = view.repeats

        // 40 ms later: another.
        #expect(scene.advanceKeyRepeat(nowNs: 700_000_000))
        #expect(view.repeats > afterFirst)

        withExtendedLifetime(window) {}
    }

    @Test func releasingTheKeyStopsTheRepeat() throws {
        let clock = TestClock()
        let scene = try makeScene(clock)
        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 105))
        #expect(scene.keyRepeatActive)

        _ = scene.dispatchInput(Self.keyEvent(.keyUp, keycode: 105))
        #expect(!scene.keyRepeatActive)
        #expect(!scene.advanceKeyRepeat(nowNs: 5_000_000_000))
    }

    /// Releasing a *different* key must not cancel the repeat of the one still
    /// held — otherwise letting go of Shift stops an arrow from repeating.
    @Test func releasingADifferentKeyLeavesTheRepeatRunning() throws {
        let clock = TestClock()
        let scene = try makeScene(clock)
        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 105))
        _ = scene.dispatchInput(Self.keyEvent(.keyUp, keycode: 42))  // KEY_LEFTSHIFT
        #expect(scene.keyRepeatActive)
    }

    /// Return and Escape must not repeat: one press firing an action many times
    /// is never what a held key should mean.
    @Test func actionKeysDoNotRepeat() throws {
        let clock = TestClock()
        let scene = try makeScene(clock)
        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 28))  // KEY_ENTER
        #expect(!scene.keyRepeatActive)

        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 1))  // KEY_ESC
        #expect(!scene.keyRepeatActive)
    }

    /// A key that produced text repeats, which is what makes holding a letter
    /// insert it repeatedly.
    @Test func aTextProducingKeyRepeats() throws {
        let clock = TestClock()
        let scene = try makeScene(clock)
        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 30, text: "a"))
        #expect(scene.keyRepeatActive)
    }

    @Test func aBareModifierDoesNotRepeat() throws {
        let clock = TestClock()
        let scene = try makeScene(clock)
        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 42))  // KEY_LEFTSHIFT
        #expect(!scene.keyRepeatActive)
    }

    /// A stalled frame must not silently swallow repeats, nor flood when it
    /// resumes.
    @Test func aLongStallCatchesUpButIsBounded() throws {
        final class CountingView: View {
            var repeats = 0
            override var acceptsFirstResponder: Bool { true }
            override func handleEvent(_ event: Event) -> EventHandling {
                if event.type == .keyDown, event.isARepeat { repeats += 1 }
                return .handled
            }
        }

        let clock = TestClock()
        let scene = try makeScene(clock)
        let view = CountingView()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Stall")
        window.setContentView(view)
        window.orderFront()
        scene.windowScene.addWindow(window)
        scene.windowScene.makeKey(window)
        #expect(window.makeFirstResponder(view))

        _ = scene.dispatchInput(Self.keyEvent(.keyDown, keycode: 105))
        // Ten seconds of stall would be 235 repeats if uncapped.
        #expect(scene.advanceKeyRepeat(nowNs: 10_000_000_000))
        #expect(view.repeats > 0)
        #expect(view.repeats <= 8, "bounded rather than flooding")

        withExtendedLifetime(window) {}
    }
}
