import Testing
import NucleusUI
@testable import NucleusShellProduct

/// The lock screen's behaviour, with emphasis on the properties that matter
/// because it is a lock screen: it fails closed, it does not retain what was
/// typed, and no amount of key-mashing queues attempts against the backend.
@MainActor
@Suite struct LockScreenViewTests {
    /// A controllable authenticator: the completion fires only when the test
    /// says so, which is how in-flight state gets exercised.
    final class StubAuthenticator: LockAuthenticator {
        var attempts: [String] = []
        var pending: ((LockAuthenticationOutcome) -> Void)?

        func authenticate(
            password: SecureBytes, completion: @escaping (LockAuthenticationOutcome) -> Void
        ) {
            // Recorded as text only so the tests can assert what was submitted;
            // a real authenticator never turns the bytes back into a String.
            attempts.append(password.withUnsafeBytes {
                String(decoding: $0, as: UTF8.self)
            })
            pending = completion
        }

        func finish(_ outcome: LockAuthenticationOutcome) {
            let completion = pending
            pending = nil
            completion?(outcome)
        }
    }

    private func makeLock() -> (LockScreenView, Window) {
        let view = LockScreenView()
        view.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        let window = Window(title: "Lock")
        window.setContentView(view)
        window.orderFront()
        view.layoutIfNeeded()
        return (view, window)
    }

    // MARK: - Failing closed

    /// With no authenticator, every attempt must fail. A lock screen that cannot
    /// check a password must not let anyone in.
    @Test func withNoAuthenticatorNothingIsAccepted() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            var unlocked = 0
            view.onAuthenticated = { unlocked += 1 }
            view.passwordField.stringValue = "anything"

            view.submit()
            #expect(unlocked == 0)
            #expect(!view.statusLabel.text.isEmpty, "and it says why")
        }
    }

    /// A backend that cannot be reached must not be reported as a wrong
    /// password: the user should not be told their credentials are bad when
    /// they may be fine.
    @Test func anUnavailableBackendIsDistinctFromARejection() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator
            var unlocked = 0
            view.onAuthenticated = { unlocked += 1 }

            view.passwordField.stringValue = "hunter2"
            view.submit()
            authenticator.finish(.unavailable("Authentication service unreachable"))

            #expect(unlocked == 0)
            #expect(view.statusLabel.text == "Authentication service unreachable")
        }
    }

    @Test func aRejectionShowsItsMessageAndDoesNotUnlock() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator
            var unlocked = 0
            view.onAuthenticated = { unlocked += 1 }

            view.passwordField.stringValue = "wrong"
            view.submit()
            authenticator.finish(.rejected("Incorrect password"))

            #expect(unlocked == 0)
            #expect(view.statusLabel.text == "Incorrect password")
        }
    }

    @Test func acceptanceUnlocksAndClearsTheStatus() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator
            var unlocked = 0
            view.onAuthenticated = { unlocked += 1 }

            view.passwordField.stringValue = "correct"
            view.submit()
            authenticator.finish(.accepted)

            #expect(unlocked == 1)
            #expect(view.statusLabel.text.isEmpty)
        }
    }

    // MARK: - Not retaining the credential

    /// The field is cleared the moment the attempt is handed off, not when the
    /// answer comes back — a password must not sit in a widget while a backend
    /// takes its time.
    @Test func thePasswordLeavesTheFieldBeforeTheAnswerArrives() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator

            view.passwordField.stringValue = "hunter2"
            view.submit()

            #expect(view.passwordField.stringValue.isEmpty, "cleared at hand-off")
            #expect(authenticator.attempts == ["hunter2"], "and the attempt still carried it")

            authenticator.finish(.rejected("no"))
            #expect(view.passwordField.stringValue.isEmpty)
        }
    }

    /// Clearing the text is not enough on its own: undo would put it back.
    @Test func aClearedPasswordIsNotRecoverableThroughUndo() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            view.authenticator = StubAuthenticator()
            view.passwordField.stringValue = "hunter2"
            view.submit()

            // Whatever an attacker at the keyboard tries, the old value is gone.
            _ = view.passwordField.handleEvent(Event(
                type: .keyDown, modifierFlags: .command, keyCode: .unknown, characters: "z"))
            #expect(view.passwordField.stringValue.isEmpty)
        }
    }

    /// The field is secure, so nothing downstream — display, clipboard,
    /// accessibility, or an input method — sees the credential.
    @Test func thePasswordFieldIsSecure() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            view.passwordField.stringValue = "hunter2"

            #expect(view.passwordField.isSecure)
            #expect(view.passwordField.accessibilityValue == nil)
            #expect(view.passwordField.textInputSurroundingContext() == nil)
            #expect(view.passwordField.textInputContentType == .password)
        }
    }

    // MARK: - Attempt rate

    /// A second submission while one is in flight is dropped, so holding Return
    /// cannot queue attempts against the backend.
    @Test func attemptsDoNotQueueWhileOneIsPending() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator

            view.passwordField.stringValue = "first"
            view.submit()
            #expect(view.isAuthenticating)

            view.passwordField.stringValue = "second"
            view.submit()
            #expect(authenticator.attempts == ["first"], "the second was dropped")

            authenticator.finish(.rejected("no"))
            #expect(!view.isAuthenticating, "and the next one may proceed")
        }
    }

    @Test func anEmptyPasswordIsNotSubmitted() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator

            view.submit()
            #expect(authenticator.attempts.isEmpty)
        }
    }

    // MARK: - Presentation

    @Test func returnInTheFieldSubmits() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            let authenticator = StubAuthenticator()
            view.authenticator = authenticator
            view.passwordField.stringValue = "typed"

            _ = view.passwordField.handleEvent(
                Event(type: .keyDown, keyCode: .return, characters: "\n"))
            #expect(authenticator.attempts == ["typed"])
        }
    }

    /// Typing must land without a click — there is nothing else on a lock screen
    /// to click.
    @Test func theFieldTakesFocusOnDemand() {
        let (view, window) = makeLock()
        withExtendedLifetime(window) {
            view.focusPasswordField()
            #expect(window.firstResponder === view.passwordField)
            #expect(view.passwordField.isFocused)
        }
    }

    /// The contents are centred from measured sizes, so the layout holds at any
    /// output size rather than assuming one.
    @Test func theContentsAreCentredAtAnyOutputSize() {
        for size in [Size(width: 800, height: 600), Size(width: 3840, height: 2160)] {
            let view = LockScreenView()
            view.frame = Rect(x: 0, y: 0, width: size.width, height: size.height)
            view.layoutIfNeeded()

            let field = view.passwordField.frame
            let column = view.subviews[0].frame
            let centreX = column.origin.x + field.origin.x + field.size.width / 2
            #expect(abs(centreX - size.width / 2) < 1.0, "horizontally centred")
            #expect(column.origin.y > 0)
            #expect(column.origin.y + column.size.height < size.height)
        }
    }
}
