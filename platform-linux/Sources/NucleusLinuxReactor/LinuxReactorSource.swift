/// A nonblocking Linux source driven by a host-owned reactor.
///
/// The contract is intentionally limited to reactor mechanics. Service
/// lifecycle and domain state remain on each concrete owner.
@MainActor
public protocol LinuxReactorSource: AnyObject {
    var fileDescriptor: Int32 { get }
    var pollEvents: Int16 { get }
    func timeoutMicroseconds() -> UInt64?

    @discardableResult
    func process() -> Bool

    func transportDidFail(operation: String)
}
