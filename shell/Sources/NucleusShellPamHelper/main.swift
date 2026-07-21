// nucleus-pam-helper — runs one PAM conversation and exits.
//
// A separate process on purpose. PAM `dlopen`s arbitrary modules configured by
// the system administrator; they allocate, spawn threads, talk to the network,
// and are entirely capable of crashing or calling `exit()`. In the shell's own
// address space any of that would kill the locker — and a dead locker leaves the
// compositor holding a permanently blank, deliberately fail-closed session. Here
// the worst case costs a child process and one failed attempt.
//
// A helper *executable* rather than a bare `fork()`: after fork in a
// multithreaded process a child may only call async-signal-safe functions, and
// PAM goes far beyond that. The shell holds a Vulkan device, GPU queues, and a
// JavaScript runtime's threads, so `posix_spawn` of a fresh image is the honest
// way to get a single-threaded process to run PAM in.
//
// Protocol: request on stdin, response on stdout, both length-prefixed. Exits 0
// accepted, 1 rejected, 2 unavailable. The password is scrubbed on every path.

import NucleusShellAuthWire
import NucleusShellPamC
#if canImport(Glibc)
import Glibc
#endif

/// Holds the password for the duration of the conversation. A class so the
/// conversation callback can reach it through `appdata_ptr`, and so there is one
/// address to scrub.
final class ConversationState {
    var password: [CChar]

    init(password: [UInt8]) {
        // NUL-terminated: PAM hands the reply to `strdup`.
        self.password = password.map { CChar(bitPattern: $0) } + [0]
    }

    func scrub() {
        password.withUnsafeMutableBytes { nucleus_pam_scrub($0.baseAddress, $0.count) }
        password = [0]
    }
}

/// The PAM conversation. Answers every echo-off prompt — the password prompt —
/// with the supplied password, answers echo-on prompts with an empty string, and
/// ignores informational and error messages.
///
/// Anything else is refused rather than guessed at: an unrecognized message
/// style means the module wants something this helper was not designed to
/// provide, and inventing an answer could satisfy a prompt it should not.
let conversation: @convention(c) (
    Int32,
    UnsafeMutablePointer<UnsafePointer<pam_message>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<pam_response>?>?,
    UnsafeMutableRawPointer?
) -> Int32 = { count, messages, responses, appdata in
    guard count > 0, let messages, let responses, let appdata else {
        return Int32(PAM_CONV_ERR)
    }
    let state = Unmanaged<ConversationState>.fromOpaque(appdata).takeUnretainedValue()
    guard let replies = nucleus_pam_alloc_responses(count) else {
        return Int32(PAM_BUF_ERR)
    }

    for index in 0..<Int(count) {
        guard let message = messages[index] else {
            nucleus_pam_free_responses(replies, count)
            return Int32(PAM_CONV_ERR)
        }

        switch message.pointee.msg_style {
        case Int32(PAM_PROMPT_ECHO_OFF):
            let ok = state.password.withUnsafeBufferPointer { buffer in
                nucleus_pam_set_response(replies, Int32(index), buffer.baseAddress)
            }
            if ok != 0 {
                nucleus_pam_free_responses(replies, count)
                return Int32(PAM_BUF_ERR)
            }
        case Int32(PAM_PROMPT_ECHO_ON):
            if nucleus_pam_set_response(replies, Int32(index), "") != 0 {
                nucleus_pam_free_responses(replies, count)
                return Int32(PAM_BUF_ERR)
            }
        case Int32(PAM_ERROR_MSG), Int32(PAM_TEXT_INFO):
            break
        default:
            nucleus_pam_free_responses(replies, count)
            return Int32(PAM_CONV_ERR)
        }
    }

    responses.pointee = replies
    return Int32(PAM_SUCCESS)
}

func respond(_ outcome: PamHelperWire.Outcome, _ message: String) -> Never {
    var buffer: [UInt8] = [outcome.rawValue]
    let messageBytes = Array(message.utf8.prefix(PamHelperWire.maximumMessageBytes))
    PamHelperWire.encodeField(messageBytes, into: &buffer)
    _ = PamHelperWire.writeAll(buffer, to: 1)
    switch outcome {
    case .accepted: exit(PamHelperWire.exitAccepted)
    case .rejected: exit(PamHelperWire.exitRejected)
    case .unavailable: exit(PamHelperWire.exitUnavailable)
    }
}

// MARK: - Request

guard let serviceLength = PamHelperWire.readLength(
        from: 0, limit: PamHelperWire.maximumServiceBytes),
      let serviceBytes = PamHelperWire.readExactly(serviceLength, from: 0),
      let passwordLength = PamHelperWire.readLength(
        from: 0, limit: PamHelperWire.maximumPasswordBytes),
      var passwordBytes = PamHelperWire.readExactly(passwordLength, from: 0)
else {
    respond(.unavailable, "Malformed authentication request")
}

let service = String(decoding: serviceBytes, as: UTF8.self)
let state = ConversationState(password: passwordBytes)
// The intermediate copy goes now; `state` owns the only one left.
passwordBytes.withUnsafeMutableBytes { nucleus_pam_scrub($0.baseAddress, $0.count) }
passwordBytes = []

var usernameBuffer = [CChar](repeating: 0, count: 256)
guard usernameBuffer.withUnsafeMutableBufferPointer({
    nucleus_pam_current_username($0.baseAddress, $0.count) == 0
}) else {
    state.scrub()
    respond(.unavailable, "Could not determine the current user")
}
let username = usernameBuffer.withUnsafeBufferPointer { buffer in
    String(
        decodingCString: UnsafeRawPointer(buffer.baseAddress!)
            .assumingMemoryBound(to: UInt8.self),
        as: UTF8.self)
}

// MARK: - Conversation

var handle: OpaquePointer?
// PAM borrows `state` through appdata only until pam_end below. The local
// strong reference remains live for that entire synchronous conversation.
var conv = pam_conv(
    conv: conversation,
    appdata_ptr: Unmanaged.passUnretained(state).toOpaque())

let startResult = pam_start(
    service.isEmpty ? "login" : service, username, &conv, &handle)
guard startResult == PAM_SUCCESS, let handle else {
    state.scrub()
    respond(.unavailable, "Could not start authentication")
}

var result = pam_authenticate(handle, 0)

if result == PAM_SUCCESS {
    // An unprivileged locker cannot read /etc/shadow, so the account stack may
    // legitimately report that it has no information. `pam_authenticate` has
    // already proved identity, so that specific answer is not a failure —
    // treating it as one would reject the correct password on most systems.
    let accountResult = pam_acct_mgmt(handle, 0)
    if accountResult != PAM_SUCCESS && accountResult != PAM_AUTHINFO_UNAVAIL {
        result = accountResult
    }
}

let description = pam_strerror(handle, result).map {
    String(
        decodingCString: UnsafeRawPointer($0)
            .assumingMemoryBound(to: UInt8.self),
        as: UTF8.self)
}
    ?? "Authentication failed"
pam_end(handle, result)
state.scrub()

if result == PAM_SUCCESS {
    respond(.accepted, "")
}
// A wrong password is a rejection; anything else is the machinery failing, and
// the user should not be told their credentials are bad for it.
switch result {
case PAM_AUTH_ERR, PAM_USER_UNKNOWN, PAM_CRED_INSUFFICIENT, PAM_MAXTRIES,
     PAM_PERM_DENIED, PAM_ACCT_EXPIRED, PAM_NEW_AUTHTOK_REQD:
    respond(.rejected, description)
default:
    respond(.unavailable, description)
}
