package import NucleusCompositorServer
package import NucleusCompositorServerTypes
package import NucleusConfig
package import NucleusSessionProtocol

/// Server-owned physical-input policy and the narrow publication seam to the
/// supervisor-provisioned out-of-process shell.
@MainActor
package final class CompositorPolicyService: CompositorPolicy {
    package typealias AcceptedActionSink =
        @MainActor (
            _ action: UInt8,
            _ configurationIndex: UInt32,
            _ value: UInt32,
            _ epoch: ConfigurationServiceEpoch,
            _ generation: ConfigurationGeneration
        ) -> Void

    package typealias WindowMenuSink =
        @MainActor (
            _ windowID: UInt64,
            _ x: Double,
            _ y: Double,
            _ capabilities: UInt32
        ) -> Void

    package typealias OverviewSink =
        @MainActor (_ outputID: DisplayID, _ state: CompositorOverviewState?) -> Void

    private let bindings: GlobalBindingResolver
    private let cursorTheme: ServerCursorThemeService
    private let gestures: CompositorGesturePolicy

    package var acceptedActionSink: AcceptedActionSink?
    package var windowMenuSink: WindowMenuSink?
    package var overviewSink: OverviewSink? {
        get { gestures.overviewSink }
        set { gestures.overviewSink = newValue }
    }
    package private(set) var configurationEpoch: ConfigurationServiceEpoch
    package private(set) var configurationGeneration: ConfigurationGeneration

    init(
        bindings: GlobalBindingResolver,
        cursorTheme: ServerCursorThemeService,
        gestures: CompositorGesturePolicy,
        configurationEpoch: ConfigurationServiceEpoch,
        configurationGeneration: ConfigurationGeneration
    ) {
        self.bindings = bindings
        self.cursorTheme = cursorTheme
        self.gestures = gestures
        self.configurationEpoch = configurationEpoch
        self.configurationGeneration = configurationGeneration
    }

    package func adoptConfiguration(
        binds: [KeyBind],
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        bindings.updateBinds(binds)
        configurationEpoch = epoch
        configurationGeneration = generation
    }

    package func adoptConfigurationVersion(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        configurationEpoch = epoch
        configurationGeneration = generation
    }

    package func dispatchKeybind(
        keycode: UInt32,
        modifiers: UInt64,
        pressed: Bool
    ) -> KeybindOutcome {
        switch bindings.bridgeDispatch(
            keycode: keycode,
            modifierBits: modifiers,
            pressed: pressed)
        {
        case .pass:
            return KeybindOutcome(
                kind: .pass, action: 0, value: 0)
        case .consume:
            return KeybindOutcome(
                kind: .consume, action: 0, value: 0)
        case .deferred(let action):
            return KeybindOutcome(
                kind: .deferred,
                action: action.kind.rawValue,
                configurationIndex: action.configurationIndex,
                value: action.value)
        }
    }

    package func dispatchGesture(
        _ event: NormalizedGestureEvent,
        target: GesturePolicyTarget?
    ) -> GesturePolicyOutcome {
        gestures.dispatch(event, target: target)
    }

    package func cancelActiveGesture() {
        gestures.cancelActiveGesture()
    }

    package func gestureOutputWillRemove(_ outputID: DisplayID) {
        gestures.outputWillRemove(outputID)
    }

    package func cursorApplyDefault() {
        cursorTheme.applyDefault()
    }

    package func cursorApplyNamed(_ name: String) {
        cursorTheme.applyNamed(name)
    }

    package func acceptedShellAction(
        action: UInt8,
        configurationIndex: UInt32,
        value: UInt32
    ) {
        acceptedActionSink?(
            action,
            configurationIndex,
            value,
            configurationEpoch,
            configurationGeneration)
    }

    package func showWindowMenu(
        windowID: UInt64,
        x: Double,
        y: Double,
        capabilities: UInt32
    ) {
        windowMenuSink?(windowID, x, y, capabilities)
    }
}
