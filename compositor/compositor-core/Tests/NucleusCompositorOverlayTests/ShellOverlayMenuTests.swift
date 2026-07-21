import NucleusCompositorOverlayTypes
import NucleusUI
import NucleusUIEmbedder
@_spi(NucleusCompositor) import NucleusLayers
@testable import NucleusCompositorOverlay
import Testing

@MainActor
@Suite(.uiContext, .serialized)
struct ShellOverlayMenuTests {
    init() {
    }

    private func makeScene() throws -> (
        ShellOverlayScene,
        ShellOverlayController
    ) {
        let scene = try ShellOverlayScene(
            frame: .init(
                outputWidth: 800,
                outputHeight: 600,
                devicePixelRatio: 1,
                overlayRegionX: 0,
                overlayRegionY: 0,
                overlayRegionW: 800,
                overlayRegionH: 600),
            commitSink: InMemoryCommitSink(),
            services: testHostServices())
        let controller = ShellOverlayController(scene: scene) { _ in }
        return (scene, controller)
    }

    private func key(_ evdev: UInt32) -> ShellOverlayInputEvent {
        ShellOverlayInputEvent(NucleusCompositorOverlayTypes.InputEvent(
            kind: .keyDown,
            keycode: evdev))
    }

    @Test
    func windowCommandsUseTheFoundationPresentationAndActivationPath() throws {
        let (scene, controller) = try makeScene()
        var selected: WindowMenuVerb?
        let menu = makeWindowMenu(
            capabilities:
                WindowMenuCapabilities.minimizable.rawValue
                | WindowMenuCapabilities.closable.rawValue
        ) {
            selected = $0
        }

        controller.showMenu(menu, at: Point(x: 760, y: 560))

        #expect(scene.menuVisible)
        #expect(scene.windowScene.menuPresentation != nil)
        #expect(scene.windowScene.popovers.count == 1)
        #expect(scene.windowScene.windows.filter {
            $0.role == .popup
        }.count == 1)

        _ = controller.dispatchInput(key(108)) // KEY_DOWN
        _ = controller.dispatchInput(key(28))  // KEY_ENTER

        #expect(selected == .minimize)
        #expect(!scene.menuVisible)
        #expect(scene.windowScene.menuPresentation == nil)
        #expect(scene.windowScene.popovers.isEmpty)
        #expect(scene.windowScene.windows.allSatisfy {
            $0.role != .popup
        })
    }

    @Test
    func disabledWindowCommandsAreSkippedByKeyboardTraversal() throws {
        let (scene, controller) = try makeScene()
        var selected: WindowMenuVerb?
        controller.showMenu(
            makeWindowMenu(
                capabilities: WindowMenuCapabilities.closable.rawValue
            ) {
                selected = $0
            },
            at: Point(x: 40, y: 40))

        _ = controller.dispatchInput(key(108))
        _ = controller.dispatchInput(key(28))

        #expect(selected == .close)
        #expect(!scene.menuVisible)
    }

    @Test
    func overlaySubmenusAndRepeatedTeardownHaveNoSeparateCascadeState() throws {
        let (scene, controller) = try makeScene()
        var activations = 0
        let leaf = MenuItem(id: "leaf", title: "Leaf") {
            activations += 1
        }
        let root = Menu(items: [
            MenuItem(
                id: "parent",
                title: "Parent",
                submenu: Menu(items: [leaf])
            ) {},
        ])

        controller.showMenu(root, at: Point(x: 100, y: 100))
        _ = controller.dispatchInput(key(108)) // root selection
        _ = controller.dispatchInput(key(106)) // KEY_RIGHT
        #expect(scene.windowScene.popovers.count == 2)
        _ = controller.dispatchInput(key(28))
        #expect(activations == 1)
        #expect(scene.windowScene.popovers.isEmpty)

        for _ in 0..<50 {
            controller.showMenu(root, at: Point(x: 100, y: 100))
            #expect(scene.dismissMenu())
        }
        #expect(!scene.menuVisible)
        #expect(scene.windowScene.popovers.isEmpty)
        #expect(scene.windowScene.windows.filter {
            $0.role == .popup
        }.isEmpty)
    }
}
