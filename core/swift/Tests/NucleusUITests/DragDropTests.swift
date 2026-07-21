import Foundation
import NucleusUI
import Testing

@MainActor
@Suite(.uiContext) struct DragDropTests {
    @MainActor
    private final class PayloadGate {
        var continuation: CheckedContinuation<Data, any Error>?

        func load() async throws -> Data {
            try await withCheckedThrowingContinuation {
                continuation = $0
            }
        }
    }

    private struct Fixture {
        let scene: WindowScene
        let source: View
        let target: View
        let preview: View
    }

    private func makeFixture(
        payload: @escaping DragSourceConfiguration.PayloadProvider,
        completion:
            @escaping @MainActor (DragCompletionOutcome) -> Void,
        events: @escaping @MainActor (String, DragDropInfo?) -> Void,
        perform:
            @escaping @MainActor (DragDropInfo, DragPayload) -> Bool
    ) -> Fixture {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 400, height: 300)

        let source = View()
        source.frame = Rect(x: 10, y: 10, width: 60, height: 40)
        source.isAccessibilityElement = true
        source.accessibilityLabel = "Source"
        root.addSubview(source)

        let scrolled = View()
        scrolled.frame = Rect(x: 150, y: 50, width: 180, height: 180)
        scrolled.boundsOrigin = Point(x: 20, y: 10)
        scrolled.transform = Transform.scale(x: 1.25, y: 1.25)
        root.addSubview(scrolled)

        let target = View()
        target.frame = Rect(x: 30, y: 25, width: 100, height: 80)
        target.isAccessibilityElement = true
        target.accessibilityLabel = "Target"
        scrolled.addSubview(target)

        let preview = View()
        preview.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        source.setDragSource(DragSourceConfiguration(
            payloadProviders: ["text/plain": payload],
            allowedOperations: [.copy, .move],
            maximumPayloadBytes: 64,
            preview: preview,
            completion: completion))
        target.setDropDestination(DropDestinationConfiguration(
            acceptedContentTypes: ["text/plain"],
            proposal: { info in
                DragDropProposal(
                    contentType: info.offer.contentTypes[0],
                    operation: .copy)
            },
            entered: { events("enter", $0) },
            updated: { events("update", $0) },
            exited: { events("exit", $0) },
            perform: { info, payload in
                events("drop", info)
                return perform(info, payload)
            }))

        let window = Window(
            title: "Drag",
            frame: Rect(x: 40, y: 30, width: 400, height: 300))
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        return Fixture(
            scene: scene,
            source: source,
            target: target,
            preview: preview)
    }

    @Test func pointerAndAccessibilityUseTheSameLifecycle() async {
        for accessibility in [false, true] {
            var names: [String] = []
            var localDropLocation: Point?
            var outcomes: [DragCompletionOutcome] = []
            let fixture = makeFixture(
                payload: { Data("hello".utf8) },
                completion: { outcomes.append($0) },
                events: { name, info in
                    names.append(name)
                    if name == "drop" {
                        localDropLocation = info?.location
                    }
                },
                perform: { _, payload in
                    payload.data == Data("hello".utf8)
                })

            if accessibility {
                _ = fixture.scene.accessibilityTree.publish()
                #expect(fixture.scene.accessibilityTree.perform(
                    AccessibilityActionRequest(
                        target: fixture.source.accessibilityID,
                        action: .startDrag)))
                #expect(fixture.scene.accessibilityTree.perform(
                    AccessibilityActionRequest(
                        target: fixture.target.accessibilityID,
                        action: .performDrop)))
                while outcomes.isEmpty {
                    await Task.yield()
                }
            } else {
                let sourcePoint =
                    fixture.scene.dragCenter(of: fixture.source)
                let targetPoint =
                    fixture.scene.dragCenter(of: fixture.target)
                #expect(fixture.scene.dispatchEvent(Event(
                    type: .pointerDragged,
                    location: sourcePoint)) == .handled)
                #expect(fixture.scene.dispatchEvent(Event(
                    type: .pointerMoved,
                    location: targetPoint)) == .handled)
                #expect(fixture.scene.dispatchEvent(Event(
                    type: .pointerUp,
                    location: targetPoint)) == .handled)
                while outcomes.isEmpty {
                    await Task.yield()
                }
            }

            #expect(names == ["enter", "update", "update", "drop"])
            #expect(outcomes == [.performed(.copy)])
            #expect(localDropLocation == Point(
                x: fixture.target.bounds.origin.x
                    + fixture.target.bounds.size.width / 2,
                y: fixture.target.bounds.origin.y
                    + fixture.target.bounds.size.height / 2))
            #expect(fixture.preview.superview == nil)
        }
    }

    @Test func leavingCancelsPendingPayloadAndRejectsStaleResult() async {
        let gate = PayloadGate()
        var applied = 0
        var outcomes: [DragCompletionOutcome] = []
        let fixture = makeFixture(
            payload: { try await gate.load() },
            completion: { outcomes.append($0) },
            events: { _, _ in },
            perform: { _, _ in
                applied += 1
                return true
            })
        let targetPoint = fixture.scene.dragCenter(of: fixture.target)
        #expect(fixture.scene.beginDrag(
            from: fixture.source,
            at: targetPoint) != nil)

        let drop = Task { @MainActor in
            await fixture.scene.drop(at: targetPoint)
        }
        while gate.continuation == nil {
            await Task.yield()
        }
        _ = fixture.scene.updateDrag(at: Point(x: 390, y: 290))
        fixture.scene.cancelDrag()
        gate.continuation?.resume(returning: Data("late".utf8))

        #expect(await drop.value == .cancelled)
        #expect(applied == 0)
        #expect(outcomes == [.cancelled])
        #expect(fixture.preview.superview == nil)
    }

    @Test func oversizedPayloadFailsWithoutCallingTheTarget() async {
        var applied = 0
        var outcomes: [DragCompletionOutcome] = []
        let fixture = makeFixture(
            payload: { Data(repeating: 1, count: 65) },
            completion: { outcomes.append($0) },
            events: { _, _ in },
            perform: { _, _ in
                applied += 1
                return true
            })
        let point = fixture.scene.dragCenter(of: fixture.target)
        _ = fixture.scene.beginDrag(from: fixture.source, at: point)

        #expect(await fixture.scene.drop(at: point) == .failed)
        #expect(applied == 0)
        #expect(outcomes == [.failed])
        #expect(fixture.preview.superview == nil)
    }

    @Test func participantRemovalAndSceneDisconnectCompleteOnce() throws {
        var outcomes: [DragCompletionOutcome] = []
        let fixture = makeFixture(
            payload: { Data() },
            completion: { outcomes.append($0) },
            events: { _, _ in },
            perform: { _, _ in true })
        let point = fixture.scene.dragCenter(of: fixture.target)
        _ = fixture.scene.beginDrag(from: fixture.source, at: point)

        fixture.target.removeFromSuperview()
        fixture.scene.cancelDrag()
        try fixture.scene.disconnect()

        #expect(outcomes == [.cancelled])
        #expect(fixture.preview.superview == nil)
    }
}
