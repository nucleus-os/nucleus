import NucleusCompositorServer
import NucleusCompositorWindowManager
import NucleusConfig
import Testing
@testable import NucleusCompositorShell

// Dispatch against a configuration-driven table. The table used to be a
// hardcoded Swift enum whose cases were the only bindable keys; these cover
// what changed when it became data.
@Suite @MainActor struct KeybindServiceTests {
    // Held for the test's lifetime: KeybindService keeps the window manager
    // `unowned`, so constructing one inline would leave a dangling reference
    // the moment an action reached it.
    private let server: NucleusCompositorServer
    private let windowManager: WindowManager

    init() {
        let server = NucleusCompositorServer()
        self.server = server
        self.windowManager = WindowManager(server: server)
    }

    private func service(_ binds: [KeyBind]) -> KeybindService {
        // No test here dispatches a launch, so the default index is fine.
        KeybindService(
            launcher: LauncherService(),
            windowManager: windowManager,
            binds: binds)
    }

    private func isDeferred(_ dispatch: KeybindService.Dispatch) -> Bool {
        if case .deferred = dispatch { return true }
        return false
    }

    private func isPass(_ dispatch: KeybindService.Dispatch) -> Bool {
        if case .pass = dispatch { return true }
        return false
    }

    // MARK: an open keycode space

    @Test func anyEvdevKeycodeIsBindable() throws {
        // W (17) was absent from the retired closed enum, so binding it was
        // previously impossible regardless of what a user asked for.
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("Super+W"), action: .closeWindow)])
        #expect(isDeferred(keybinds.dispatch(
            keycode: 17, modifiers: .superKey, phase: .down)))
    }

    @Test func mediaKeysDispatchWithNoModifiers() throws {
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("VolumeUp"),
            action: .adjustBackdropIntensity(0.1))])
        #expect(isDeferred(keybinds.dispatch(
            keycode: 115, modifiers: [], phase: .down)))
    }

    // MARK: matching

    @Test func anUnboundChordPassesThrough() throws {
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("Super+Q"), action: .closeWindow)])
        #expect(isPass(keybinds.dispatch(
            keycode: 16, modifiers: [], phase: .down)))
        #expect(isPass(keybinds.dispatch(
            keycode: 17, modifiers: .superKey, phase: .down)))
    }

    @Test func modifiersMustMatchExactly() throws {
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("Super+Q"), action: .closeWindow)])
        // A superset of the bound modifiers is a different chord, not a match.
        #expect(isPass(keybinds.dispatch(
            keycode: 16, modifiers: [.superKey, .shift], phase: .down)))
    }

    @Test func modifierKeysThemselvesNeverMatch() {
        // Left Super is 125; pressing it must not resolve as a bind.
        let keybinds = service([KeyBind(
            keys: KeyChord(modifiers: [], keyCode: 125),
            action: .closeWindow)])
        #expect(isPass(keybinds.dispatch(
            keycode: 125, modifiers: [], phase: .down)))
    }

    @Test func aLaterDuplicateChordWins() throws {
        // A file that binds the same chord twice should take its last word
        // rather than an arbitrary one.
        let keybinds = service([
            KeyBind(
                keys: try KeyChord.parse("Super+Q"),
                action: .activateWorkspace(1)),
            KeyBind(
                keys: try KeyChord.parse("Super+Q"),
                action: .activateWorkspace(7)),
        ])
        guard case .deferred(let action) = keybinds.dispatch(
            keycode: 16, modifiers: .superKey, phase: .down)
        else {
            Issue.record("expected a deferred action")
            return
        }
        #expect(action.value == 7)
    }

    // MARK: capture across phases

    @Test func aCapturedKeyConsumesItsOwnRelease() throws {
        // The client never saw the press, so it must not see the release
        // either, or it is left believing the key is still held.
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("Super+Q"), action: .closeWindow)])
        #expect(isDeferred(keybinds.dispatch(
            keycode: 16, modifiers: .superKey, phase: .down)))
        if case .consume = keybinds.dispatch(
            keycode: 16, modifiers: [], phase: .up) {} else {
            Issue.record("release of a captured key was not consumed")
        }
    }

    @Test func anUncapturedReleasePassesThrough() {
        let keybinds = service([])
        #expect(isPass(keybinds.dispatch(
            keycode: 16, modifiers: [], phase: .up)))
    }

    // MARK: reload

    @Test func updatingBindsReplacesTheTableOutright() throws {
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("Super+Q"), action: .closeWindow)])
        keybinds.updateBinds([KeyBind(
            keys: try KeyChord.parse("Super+W"), action: .closeWindow)])

        #expect(isPass(keybinds.dispatch(
            keycode: 16, modifiers: .superKey, phase: .down)))
        #expect(isDeferred(keybinds.dispatch(
            keycode: 17, modifiers: .superKey, phase: .down)))
    }

    @Test func updatingBindsReleasesKeysTheOldTableCaptured() throws {
        let keybinds = service([KeyBind(
            keys: try KeyChord.parse("Super+Q"), action: .closeWindow)])
        _ = keybinds.dispatch(keycode: 16, modifiers: .superKey, phase: .down)

        // Reloading mid-press must not leave the release consumed by a table
        // that no longer binds it — the client that now owns the key would be
        // stuck with it held down.
        keybinds.updateBinds([])
        #expect(isPass(keybinds.dispatch(
            keycode: 16, modifiers: [], phase: .up)))
    }

    // MARK: wire mapping

    @Test func tileDirectionsMapOntoTheTileCommandWireValues() {
        #expect(KeybindService.wireValue(.left) == 1)
        #expect(KeybindService.wireValue(.right) == 2)
        #expect(KeybindService.wireValue(.top) == 3)
        #expect(KeybindService.wireValue(.bottom) == 4)
        #expect(KeybindService.wireValue(.topLeft) == 5)
        #expect(KeybindService.wireValue(.topRight) == 6)
        #expect(KeybindService.wireValue(.bottomLeft) == 7)
        #expect(KeybindService.wireValue(.bottomRight) == 8)
        #expect(KeybindService.wireValue(.maximize) == 9)
    }

    @Test func reactorModifierBitsDecodeToTheSharedOptionSet() {
        // CGEventFlags-shaped packing: shift=17, control=18, alt=19, super=20.
        #expect(KeybindService.decode(modifierBits: 1 << 17) == .shift)
        #expect(KeybindService.decode(modifierBits: 1 << 18) == .control)
        #expect(KeybindService.decode(modifierBits: 1 << 19) == .alt)
        #expect(KeybindService.decode(modifierBits: 1 << 20) == .superKey)
        #expect(KeybindService.decode(modifierBits: (1 << 17) | (1 << 20))
            == [.shift, .superKey])
        #expect(KeybindService.decode(modifierBits: 0) == [])
    }

    // MARK: defaults

    @Test func theDefaultTableBindsItsDocumentedChords() {
        let keybinds = service(DefaultBinds.table)
        // Super+Q closes, Ctrl+Alt+Left tiles, Super+3 switches workspace.
        #expect(isDeferred(keybinds.dispatch(
            keycode: 16, modifiers: .superKey, phase: .down)))
        #expect(isDeferred(keybinds.dispatch(
            keycode: 105, modifiers: [.control, .alt], phase: .down)))
        guard case .deferred(let workspace) = keybinds.dispatch(
            keycode: 4, modifiers: .superKey, phase: .down)
        else {
            Issue.record("Super+3 did not resolve")
            return
        }
        #expect(workspace.value == 3)
    }
}
