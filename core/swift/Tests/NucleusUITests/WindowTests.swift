@_spi(NucleusCompositor) @testable import NucleusUI
import class NucleusLayers.Context
import struct NucleusLayers.ContextID
import class NucleusLayers.InMemoryCommitSink
import Testing

@MainActor
@Suite(.uiContext) struct WindowTests {
    final class TrackingViewController: ViewController {
        let loadedView: View
        var didLoadCount = 0
        var willAppearCount = 0

        init(loadedView: View) throws {
            self.loadedView = loadedView
            super.init()
        }

        override func loadView() {
            setView(loadedView)
        }

        override func viewDidLoad() {
            didLoadCount += 1
        }

        override func viewWillAppear() {
            willAppearCount += 1
        }
    }

    @Test func windowSetTitleStoresUTF8() throws {
        let window = Window(title: "Initial")
        #expect(window.title == "Initial")

        window.setTitle("Résumé 🚀")
        #expect(window.title == "Résumé 🚀")
    }

    @Test func windowStoresRoleLevelAndHitTestingParticipation() throws {
        let window = Window(
            title: "Notifications",
            role: .notification,
            level: .overlay,
            participatesInHitTesting: false
        )

        #expect(window.role == .notification)
        #expect(window.level == .overlay)
        #expect(!window.participatesInHitTesting)

        window.role = .overlay
        window.level = .criticalOverlay
        window.participatesInHitTesting = true

        #expect(window.role == .overlay)
        #expect(window.level == .criticalOverlay)
        #expect(window.participatesInHitTesting)
    }

    @Test func contentViewControllerOwnsWindowContentLifecycle() throws {
        let window = Window(
            title: "Overlay",
            frame: Rect(x: 10, y: 20, width: 320, height: 180)
        )
        let view = View()
        let controller = try TrackingViewController(loadedView: view)

        window.setContentViewController(controller)

        #expect(window.contentView === view)
        #expect(window.root === view)
        #expect(window.frame == Rect(x: 10, y: 20, width: 320, height: 180))
        #expect(view.frame == Rect(x: 0, y: 0, width: 320, height: 180))
        #expect(controller.didLoadCount == 1)
        #expect(view.nextResponder === controller)

        window.orderFront()
        window.makeKey()

        #expect(window.isVisible)
        #expect(window.isKeyWindow)
        #expect(controller.willAppearCount == 1)

        window.orderOut()

        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func windowFrameIsTheContentFrameAuthority() throws {
        let window = Window(title: "Sized", frame: Rect(x: 4, y: 5, width: 120, height: 90))
        let view = View()

        window.setContentView(view)
        #expect(view.frame == Rect(x: 0, y: 0, width: 120, height: 90))

        window.setFrame(Rect(x: 20, y: 30, width: 400, height: 300))
        #expect(window.frame == Rect(x: 20, y: 30, width: 400, height: 300))
        #expect(view.frame == Rect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.needsDisplay)
    }

    @Test func windowAndSceneConversionsKeepTheContentOriginLocal() {
        let window = Window(
            title: "Placed",
            frame: Rect(x: 125.5, y: 48.25, width: 320, height: 180)
        )
        let root = View()
        window.setContentView(root)

        #expect(root.frame.origin == .zero)
        #expect(window.scenePoint(fromWindow: Point(x: 7.25, y: 9.5))
            == Point(x: 132.75, y: 57.75))
        #expect(window.windowPoint(fromScene: Point(x: 132.75, y: 57.75))
            == Point(x: 7.25, y: 9.5))
        #expect(window.sceneRect(fromWindow: Rect(x: 7.25, y: 9.5, width: 30, height: 20))
            == Rect(x: 132.75, y: 57.75, width: 30, height: 20))
        #expect(window.windowRect(fromScene: Rect(x: 132.75, y: 57.75, width: 30, height: 20))
            == Rect(x: 7.25, y: 9.5, width: 30, height: 20))
    }

    @Test func windowSceneOwnsOrderingVisibilityAndKeyWindow() throws {
        let visualContext = try Context(id: ContextID(rawValue: 810), commitSink: InMemoryCommitSink())
        let normal = Window(title: "Normal", frame: Rect(x: 0, y: 0, width: 100, height: 100))
        let overlay = Window(
            title: "Overlay",
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            level: .overlay
        )
        normal.setContentView(View())
        overlay.setContentView(View())
        let scene = WindowScene(
            windows: [overlay, normal],
            uiContext: normal.uiContext,
            visualContext: visualContext)

        normal.orderFront()
        overlay.orderFront()
        normal.makeKey()

        #expect(scene.windows.map(\.title) == ["Normal", "Overlay"])
        #expect(scene.keyWindow === normal)
        #expect(normal.isKeyWindow)
        #expect(overlay.isVisible)

        let hit = try #require(scene.hitTestWindow(at: Point(x: 10, y: 10)))
        #expect(hit === overlay)

        overlay.orderOut()
        #expect(!overlay.isVisible)
    }

    @Test func titledWindowAllocatesTitlebarOnInit() throws {
        let window = Window(
            title: "Titled",
            frame: Rect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable]
        )
        let titlebar = try #require(window.titlebar)
        #expect(titlebar.material == .titlebar)
    }

    @Test func untitledWindowHasNilTitlebar() throws {
        let window = Window(title: "No chrome", frame: Rect(x: 0, y: 0, width: 100, height: 100))
        #expect(window.titlebar == nil)
    }

    @Test func togglingTitledStyleAllocatesAndClearsTitlebar() throws {
        let window = Window(title: "Toggle", frame: Rect(x: 0, y: 0, width: 100, height: 100))
        #expect(window.titlebar == nil)

        window.styleMask = [.titled]
        let first = try #require(window.titlebar)
        #expect(first.material == .titlebar)

        window.styleMask = []
        #expect(window.titlebar == nil)

        window.styleMask = [.titled, .resizable]
        let second = try #require(window.titlebar)
        #expect(second.material == .titlebar)
        // Re-toggling allocates a fresh view (the previous one was
        // cleared); identity isn't preserved across `.titled` off/on.
        #expect(first !== second)
    }

    @Test func togglingNonTitledStyleBitsDoesNotReplaceTitlebar() throws {
        let window = Window(
            title: "Resize",
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled]
        )
        let original = try #require(window.titlebar)
        window.styleMask = [.titled, .closable]
        #expect(window.titlebar === original)
    }

    @Test func titlebarStateOverrideWritesThroughToLayer() throws {
        let window = Window(
            title: "Stateful",
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled]
        )
        let titlebar = try #require(window.titlebar)
        titlebar.state = .inactive
        #expect(titlebar.properties.backdropMaterial?.state == .inactive)
    }
}
