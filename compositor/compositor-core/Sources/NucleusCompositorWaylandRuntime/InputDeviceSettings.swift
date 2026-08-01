// InputDeviceSettings — configuration applied to physical input devices.
//
// Split deliberately in two. Classifying a device and deciding which settings
// that class receives is pure value work and is where every interesting rule
// lives, so it is testable without hardware. Handing those values to libinput
// is an unconditional translation with no decisions left in it.
//
// Without this the compositor made no libinput configuration calls at all, so
// every device ran on libinput's defaults — which leave tap-to-click off, and
// read as broken hardware on a laptop.

import Glibc
import NucleusCompositorInputC
package import NucleusConfig

/// How libinput's own defaults classify a pointing device.
///
/// libinput exposes no direct "is a touchpad" query, so this follows the same
/// discrimination Mutter, sway, and niri use: tap finger count for touchpads,
/// udev properties for the two pointing devices that are not mice.
package enum InputDeviceClass: Equatable, Sendable {
    case touchpad
    case mouse
    case trackpoint
    case trackball
    /// Keyboards, touchscreens, and anything with no pointer configuration.
    case unclassified
}

/// The settings one device should receive.
///
/// `nil` means *leave the device's own default alone* rather than *set false* —
/// the distinction matters because libinput's per-device defaults encode
/// hardware knowledge the compositor does not have.
package struct ResolvedDeviceSettings: Equatable, Sendable {
    package var tap: Bool?
    package var tapButtonMap: TapButtonMap?
    package var clickMethod: ClickMethod?
    package var disableWhileTyping: Bool?
    package var disableWhileTrackpointing: Bool?
    package var naturalScroll: Bool?
    package var accelSpeed: Double?
    package var accelProfile: AccelProfile?
    package var scrollMethod: ScrollMethod?
    package var scrollButton: UInt32?
    package var middleEmulation: Bool?
    package var leftHanded: Bool?

    package init() {}

    /// libinput rejects an acceleration speed outside [-1, 1]. The config layer
    /// warns about it; clamping here keeps an out-of-range value from silently
    /// discarding every other setting on the device.
    private static func clampedAccel(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    package static func resolve(
        _ config: InputConfig, for deviceClass: InputDeviceClass
    ) -> ResolvedDeviceSettings {
        var settings = ResolvedDeviceSettings()
        switch deviceClass {
        case .touchpad:
            let touchpad = config.touchpad
            settings.tap = touchpad.tap
            settings.tapButtonMap = touchpad.tapButtonMap
            settings.clickMethod = touchpad.clickMethod
            settings.disableWhileTyping = touchpad.disableWhileTyping
            settings.disableWhileTrackpointing =
                touchpad.disableWhileTrackpointing
            settings.naturalScroll = touchpad.naturalScroll
            settings.accelSpeed = clampedAccel(touchpad.accelSpeed)
            settings.accelProfile = touchpad.accelProfile
            settings.scrollMethod = touchpad.scrollMethod
            settings.middleEmulation = touchpad.middleEmulation
            settings.leftHanded = touchpad.leftHanded
        case .mouse:
            settings.applyPointer(config.mouse)
        case .trackpoint:
            settings.applyPointer(config.trackpoint)
        case .trackball:
            settings.applyPointer(config.trackball)
        case .unclassified:
            break
        }
        return settings
    }

    /// Tap, click method, and the disable-while-* settings are touchpad-only;
    /// a pointing device that is not a touchpad leaves them untouched.
    private mutating func applyPointer(_ pointer: PointerConfig) {
        naturalScroll = pointer.naturalScroll
        accelSpeed = Self.clampedAccel(pointer.accelSpeed)
        accelProfile = pointer.accelProfile
        scrollMethod = pointer.scrollMethod
        middleEmulation = pointer.middleEmulation
        leftHanded = pointer.leftHanded
        // Only meaningful when scrolling is bound to a held button; sending it
        // otherwise is harmless but says something the user did not ask for.
        if pointer.scrollMethod == .onButtonDown, pointer.scrollButton != 0 {
            scrollButton = pointer.scrollButton
        }
    }
}

// MARK: - libinput translation

enum InputDeviceConfiguration {
    /// Classify a live libinput device.
    @unsafe static func classify(_ device: OpaquePointer) -> InputDeviceClass {
        // Mutter's discrimination, which the other compositors follow: only a
        // touchpad reports a tap finger count.
        if unsafe libinput_device_config_tap_get_finger_count(device) > 0 {
            return .touchpad
        }
        guard
            unsafe libinput_device_has_capability(
                device, LIBINPUT_DEVICE_CAP_POINTER) != 0
        else { return .unclassified }

        if let udev = unsafe libinput_device_get_udev_device(device) {
            defer { unsafe udev_device_unref(udev) }
            if unsafe udev_device_get_property_value(
                udev, "ID_INPUT_TRACKBALL") != nil
            {
                return .trackball
            }
            if unsafe udev_device_get_property_value(
                udev, "ID_INPUT_POINTINGSTICK") != nil
            {
                return .trackpoint
            }
        }
        return .mouse
    }

    /// Apply configuration to one device.
    ///
    /// Every setter's status is discarded on purpose: libinput answers
    /// `UNSUPPORTED` for a capability the hardware lacks, and that is an
    /// ordinary outcome, not a failure worth surfacing per device.
    @unsafe static func apply(_ config: InputConfig, to device: OpaquePointer) {
        let settings = unsafe ResolvedDeviceSettings.resolve(
            config, for: classify(device))

        if let tap = settings.tap {
            _ = unsafe libinput_device_config_tap_set_enabled(
                device,
                tap
                    ? LIBINPUT_CONFIG_TAP_ENABLED
                    : LIBINPUT_CONFIG_TAP_DISABLED)
        }
        if let map = settings.tapButtonMap {
            _ = unsafe libinput_device_config_tap_set_button_map(
                device,
                map == .leftRightMiddle
                    ? LIBINPUT_CONFIG_TAP_MAP_LRM : LIBINPUT_CONFIG_TAP_MAP_LMR)
        }
        if let method = settings.clickMethod {
            _ = unsafe libinput_device_config_click_set_method(
                device,
                method == .clickfinger
                    ? LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER
                    : LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS)
        }
        if let dwt = settings.disableWhileTyping {
            _ = unsafe libinput_device_config_dwt_set_enabled(
                device,
                dwt
                    ? LIBINPUT_CONFIG_DWT_ENABLED
                    : LIBINPUT_CONFIG_DWT_DISABLED)
        }
        if let dwtp = settings.disableWhileTrackpointing {
            _ = unsafe libinput_device_config_dwtp_set_enabled(
                device,
                dwtp
                    ? LIBINPUT_CONFIG_DWTP_ENABLED
                    : LIBINPUT_CONFIG_DWTP_DISABLED)
        }
        if let natural = settings.naturalScroll {
            _ = unsafe libinput_device_config_scroll_set_natural_scroll_enabled(
                device, natural ? 1 : 0)
        }
        if let speed = settings.accelSpeed {
            _ = unsafe libinput_device_config_accel_set_speed(device, speed)
        }
        if let profile = settings.accelProfile {
            _ = unsafe libinput_device_config_accel_set_profile(
                device,
                profile == .flat
                    ? LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT
                    : LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE)
        }
        if let method = settings.scrollMethod {
            _ = unsafe libinput_device_config_scroll_set_method(
                device, scrollMethod(method))
        }
        if let button = settings.scrollButton {
            _ = unsafe libinput_device_config_scroll_set_button(device, button)
        }
        if let middle = settings.middleEmulation {
            _ = unsafe libinput_device_config_middle_emulation_set_enabled(
                device,
                middle
                    ? LIBINPUT_CONFIG_MIDDLE_EMULATION_ENABLED
                    : LIBINPUT_CONFIG_MIDDLE_EMULATION_DISABLED)
        }
        if let left = settings.leftHanded {
            _ = unsafe libinput_device_config_left_handed_set(
                device, left ? 1 : 0)
        }
    }

    private static func scrollMethod(
        _ method: ScrollMethod
    ) -> libinput_config_scroll_method {
        switch method {
        case .noScroll: LIBINPUT_CONFIG_SCROLL_NO_SCROLL
        case .twoFinger: LIBINPUT_CONFIG_SCROLL_2FG
        case .edge: LIBINPUT_CONFIG_SCROLL_EDGE
        case .onButtonDown: LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN
        }
    }
}
