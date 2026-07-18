@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct ActionTests {
    @Test func setAndPerformActionCallsHandler() throws {
        let view = View()
        let action = ActionID(rawValue: 1)
        var callCount = 0

        view.setAction(action) { event in
            callCount += 1
            #expect(event == Event(
                type: .pointerDown,
                location: Point(x: 10, y: 20),
                timestampNanoseconds: 123,
                button: .middle
            ))
        }

        let handled = view.performAction(action, event: Event(
            type: .pointerDown,
            location: Point(x: 10, y: 20),
            timestampNanoseconds: 123,
            button: .middle
        ))
        #expect(handled)
        #expect(callCount == 1)
    }

    @Test func clearActionPreventsLaterCalls() throws {
        let view = View()
        let action = ActionID(rawValue: 2)
        var callCount = 0

        view.setAction(action) { _ in
            callCount += 1
        }
        view.clearAction(action)

        #expect(!view.performAction(action, event: Event(type: .action)))
        #expect(callCount == 0)
    }

    @Test func performActionWithoutHandlerReportsUnhandled() throws {
        let view = View()

        #expect(!view.performAction(ActionID(rawValue: 99), event: Event(type: .action)))
    }

    @Test func performActionWalksTheResponderChainAndReportsHandled() throws {
        let parent = View()
        let child = View()
        parent.addSubview(child)
        let action = ActionID(rawValue: 7)
        var callCount = 0

        parent.setAction(action) { _ in
            callCount += 1
        }

        #expect(child.performAction(action, event: Event(type: .action)))
        #expect(callCount == 1)
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

        let view = View()
        let action = ActionID(rawValue: 4)
        var disposed = false
        do {
            let token = Token {
                disposed = true
            }
            view.setAction(action) { [token] _ in
                _ = token
            }
        }

        view.setAction(action) { _ in }
        #expect(disposed)
    }
}
