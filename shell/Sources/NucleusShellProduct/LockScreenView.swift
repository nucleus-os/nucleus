import NucleusUI

/// What a password attempt produced. The view never decides this itself — it
/// hands the attempt to an authenticator and renders the answer.
public enum LockAuthenticationOutcome: Sendable, Equatable {
    case accepted
    /// Wrong credentials. The message is shown to the user, so it must never
    /// contain anything derived from what they typed.
    case rejected(String)
    /// The authenticator could not reach its backend. Distinct from `rejected`
    /// because retrying may work and the user should not be told their password
    /// is wrong when it might not be.
    case unavailable(String)
}

/// Verifies a password. Implemented outside this package — PAM, a keyring, a
/// test stub — so the lock UI never links an authentication backend.
///
/// The credential arrives as `SecureBytes` rather than a `String` because a
/// `String` cannot be scrubbed: its storage is copy-on-write, small values live
/// inline, and the compiler may copy it anywhere. An implementation must not
/// copy the bytes into anything longer-lived than the call.
///
/// Verification is asynchronous because every real backend is, and because a
/// synchronous one would freeze the lock screen for the duration of a
/// deliberately slow check.
@MainActor
public protocol LockAuthenticator: AnyObject {
    func authenticate(
        password: SecureBytes,
        completion: @escaping (LockAuthenticationOutcome) -> Void)
}

/// The session lock screen: a prompt, a secure password field, and a status line.
///
/// Authored entirely against NucleusUI's public API, in the product tier. It
/// owns no Wayland, render, or authentication vocabulary — the lock *protocol*
/// is the runtime's job and the credential check is the authenticator's. This
/// view's whole responsibility is presenting the prompt and reporting attempts.
@MainActor
public final class LockScreenView: View {
    public let promptLabel: Label
    public let passwordField: TextField
    public let statusLabel: Label

    /// Verifies attempts. With none set the field still works and every attempt
    /// reports unavailable — a lock screen that cannot authenticate must fail
    /// closed, never open.
    public weak var authenticator: (any LockAuthenticator)?

    /// Called on a successful attempt. The runtime unlocks the session here.
    public var onAuthenticated: (() -> Void)?

    /// Whether an attempt is in flight. A second Return while one is pending is
    /// ignored, so a held key cannot queue attempts against the backend.
    public private(set) var isAuthenticating = false

    private let column: StackView

    public init(prompt: String = "Enter your password") {
        column = StackView(axis: .vertical, spacing: 10, alignment: .center)
        promptLabel = Label(prompt)
        passwordField = TextField(string: "", isSecure: true)
        statusLabel = Label("")
        super.init()

        backgroundColor = Color(0.05, 0.06, 0.09, 1)

        promptLabel.font = .systemFont(ofSize: 15)
        promptLabel.textColor = Color(0.92, 0.94, 0.97, 1)

        passwordField.frame = Rect(x: 0, y: 0, width: 260, height: 30)
        passwordField.layoutBasis = 30
        passwordField.placeholderString = "Password"
        passwordField.contentType = .password
        passwordField.style = ViewStyle(cornerRadius: 6)
        passwordField.backgroundColor = Color(1, 1, 1, 0.08)
        passwordField.onSubmit = { [weak self] _ in self?.submit() }

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Color(0.95, 0.55, 0.55, 1)

        column.setArrangedBody {
            promptLabel
            passwordField
            statusLabel
        }
        setBody { column }
    }

    /// The field takes focus so typing lands somewhere without a click — there
    /// is nothing else on a lock screen to click.
    public func focusPasswordField() {
        _ = window?.makeFirstResponder(passwordField)
    }

    public override func layout() {
        // Centred both ways. The column measures itself from its children, so
        // nothing here hardcodes the field's or the labels' sizes.
        let size = column.measure(LayoutConstraints(maxWidth: bounds.size.width))
        let width = max(size.width, 260)
        column.arrange(in: Rect(
            x: (bounds.size.width - width) / 2,
            y: (bounds.size.height - size.height) / 2,
            width: width,
            height: size.height))
    }

    /// Submit the current password. Clears the field immediately, whatever the
    /// outcome — a password must not sit in a widget waiting to be shoulder-read
    /// or recovered from a later state dump.
    public func submit() {
        guard !isAuthenticating else { return }
        guard let authenticator else {
            // Fail closed: no backend means no entry, and say so honestly rather
            // than claiming the password was wrong.
            statusLabel.text = "Authentication is unavailable"
            clearPassword()
            return
        }

        // Taking the credential empties the field and its undo history in one
        // step, so nothing recoverable is left behind while the check runs.
        let password = passwordField.takeSecureCredential()
        guard !password.isEmpty else { return }
        passwordField.discardUndoHistory()

        isAuthenticating = true
        statusLabel.text = ""
        authenticator.authenticate(password: password) { [weak self] outcome in
            guard let self else { return }
            isAuthenticating = false
            switch outcome {
            case .accepted:
                statusLabel.text = ""
                onAuthenticated?()
            case .rejected(let message):
                statusLabel.text = message
            case .unavailable(let message):
                statusLabel.text = message
            }
        }
    }

    /// Drop the entered password and its undo history. `stringValue` alone would
    /// leave the old text recoverable through undo, which on a lock screen is a
    /// credential sitting in a buffer.
    public func clearPassword() {
        passwordField.stringValue = ""
        passwordField.discardUndoHistory()
    }
}
