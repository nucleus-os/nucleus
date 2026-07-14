@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct ActionTests {
    @Test func setAndPerformActionCallsHandler() throws {
        let view = try View()
        let action = ActionID(rawValue: 1)
        var callCount = 0

        try view.setAction(action) { event in
            callCount += 1
            #expect(event == Event(
                type: .pointerDown,
                button: 2,
                location: Point(x: 10, y: 20),
                timestampNanoseconds: 123
            ))
        }

        try view.performAction(action, event: Event(
            type: .pointerDown,
            button: 2,
            location: Point(x: 10, y: 20),
            timestampNanoseconds: 123
        ))
        #expect(callCount == 1)
    }

    @Test func clearActionPreventsLaterCalls() throws {
        let view = try View()
        let action = ActionID(rawValue: 2)
        var callCount = 0

        try view.setAction(action) { _ in
            callCount += 1
        }
        try view.clearAction(action)

        #expect(throws: UIError.notImplemented(detail: "responder action is not registered")) {
            try view.performAction(action, event: Event(type: .action))
        }
        #expect(callCount == 0)
    }

    @Test func performActionWithoutHandlerThrowsNotImplemented() throws {
        let view = try View()

        do {
            try view.performAction(ActionID(rawValue: 99), event: Event(type: .action))
            Issue.record("expected performAction to throw")
        } catch UIError.notImplemented {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func replacingActionReleasesPreviousHandlerCaptures() throws {
        final class Token {
            var onDeinit: () -> Void
            init(onDeinit: @escaping () -> Void) {
                self.onDeinit = onDeinit
            }
            deinit {
                onDeinit()
            }
        }

        let view = try View()
        let action = ActionID(rawValue: 4)
        var disposed = false
        do {
            let token = Token {
                disposed = true
            }
            try view.setAction(action) { [token] _ in
                _ = token
            }
        }

        try view.setAction(action) { _ in }
        #expect(disposed)
    }
}
