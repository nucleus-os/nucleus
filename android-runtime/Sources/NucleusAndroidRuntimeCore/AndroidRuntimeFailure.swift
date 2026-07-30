public struct AndroidRuntimeFailure:
    Error, Equatable, Sendable, CustomStringConvertible
{
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
