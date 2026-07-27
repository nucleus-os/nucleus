import NucleusConfig
import Testing
@testable import NucleusCompositorWaylandRuntime

// Which settings a device class receives, and what happens to values libinput
// would reject. Classification itself needs a live device; everything that
// decides *what to send* is pure and lives here.
@Suite struct InputDeviceSettingsTests {
    private func configuration(
        _ mutate: (inout InputConfig) -> Void = { _ in }
    ) -> InputConfig {
        var config = InputConfig.defaults
        mutate(&config)
        return config
    }

    // MARK: touchpad

    @Test func aTouchpadReceivesTheTouchpadBlock() {
        let settings = ResolvedDeviceSettings.resolve(
            configuration(), for: .touchpad)
        #expect(settings.tap == TouchpadConfig.defaults.tap)
        #expect(settings.naturalScroll == TouchpadConfig.defaults.naturalScroll)
        #expect(settings.clickMethod == TouchpadConfig.defaults.clickMethod)
        #expect(settings.disableWhileTyping
            == TouchpadConfig.defaults.disableWhileTyping)
    }

    @Test func tapToClickAndNaturalScrollDefaultOn() {
        // libinput's own defaults leave both off, which reads as broken
        // hardware on a laptop. This is the override that makes it usable.
        let settings = ResolvedDeviceSettings.resolve(
            configuration(), for: .touchpad)
        #expect(settings.tap == true)
        #expect(settings.naturalScroll == true)
    }

    // MARK: non-touchpad pointing devices

    @Test func aMouseNeverReceivesTouchpadOnlySettings() {
        let settings = ResolvedDeviceSettings.resolve(
            configuration(), for: .mouse)
        // nil means "leave libinput's own default alone", which is the correct
        // outcome for a setting that does not apply to this hardware.
        #expect(settings.tap == nil)
        #expect(settings.tapButtonMap == nil)
        #expect(settings.clickMethod == nil)
        #expect(settings.disableWhileTyping == nil)
        #expect(settings.disableWhileTrackpointing == nil)
        // Shared pointer settings still arrive.
        #expect(settings.accelSpeed == PointerConfig.mouseDefaults.accelSpeed)
        #expect(settings.naturalScroll
            == PointerConfig.mouseDefaults.naturalScroll)
    }

    @Test func eachPointingClassReadsItsOwnBlock() {
        let config = configuration {
            $0.mouse.accelSpeed = 0.1
            $0.trackpoint.accelSpeed = 0.2
            $0.trackball.accelSpeed = 0.3
        }
        #expect(ResolvedDeviceSettings.resolve(config, for: .mouse)
            .accelSpeed == 0.1)
        #expect(ResolvedDeviceSettings.resolve(config, for: .trackpoint)
            .accelSpeed == 0.2)
        #expect(ResolvedDeviceSettings.resolve(config, for: .trackball)
            .accelSpeed == 0.3)
    }

    @Test func anUnclassifiedDeviceReceivesNothing() {
        let settings = ResolvedDeviceSettings.resolve(
            configuration(), for: .unclassified)
        #expect(settings == ResolvedDeviceSettings())
    }

    // MARK: scroll button

    @Test func theScrollButtonIsSentOnlyWhenScrollingIsBoundToAButton() {
        let bound = configuration {
            $0.mouse.scrollMethod = .onButtonDown
            $0.mouse.scrollButton = 274
        }
        #expect(ResolvedDeviceSettings.resolve(bound, for: .mouse)
            .scrollButton == 274)

        let unbound = configuration {
            $0.mouse.scrollMethod = .twoFinger
            $0.mouse.scrollButton = 274
        }
        #expect(ResolvedDeviceSettings.resolve(unbound, for: .mouse)
            .scrollButton == nil)
    }

    @Test func azeroScrollButtonIsTreatedAsUnset() {
        let config = configuration {
            $0.mouse.scrollMethod = .onButtonDown
            $0.mouse.scrollButton = 0
        }
        #expect(ResolvedDeviceSettings.resolve(config, for: .mouse)
            .scrollButton == nil)
    }

    // MARK: range handling

    @Test func anOutOfRangeAccelSpeedIsClampedRatherThanDroppingTheDevice() {
        // libinput rejects anything outside [-1, 1]. Clamping keeps one bad
        // value from taking every other setting on the device down with it.
        let high = configuration { $0.touchpad.accelSpeed = 4.5 }
        #expect(ResolvedDeviceSettings.resolve(high, for: .touchpad)
            .accelSpeed == 1)

        let low = configuration { $0.mouse.accelSpeed = -9 }
        #expect(ResolvedDeviceSettings.resolve(low, for: .mouse)
            .accelSpeed == -1)
    }

    @Test func anInRangeAccelSpeedPassesThroughUnchanged() {
        let config = configuration { $0.touchpad.accelSpeed = -0.75 }
        #expect(ResolvedDeviceSettings.resolve(config, for: .touchpad)
            .accelSpeed == -0.75)
    }

    // MARK: xkb rules

    @Test func xkbRulesCarryOnlyTheFieldsTheUserSet() {
        let config = configuration { $0.keyboard.xkb.layout = "us,de" }
        let rules = InputHost.xkbRules(for: config)
        #expect(rules.layout == "us,de")
        #expect(rules.model.isEmpty)
        #expect(!rules.isEmpty)
    }

    @Test func anUnsetXkbBlockIsEmptySoXkbcommonResolvesItsOwnDefaults() {
        #expect(InputHost.xkbRules(for: configuration()).isEmpty)
    }
}
