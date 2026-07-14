public enum UIError: Error, Equatable, Sendable {
    case invalidHandle(detail: String?)
    case outOfMemory
    case invalidArgument(detail: String?)
    case backendFailure(detail: String?)
    case notImplemented(detail: String?)
    case unknown(code: Int32, detail: String?)
}
