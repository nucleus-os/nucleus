/// A platform presentation clock that grants one callback at a time.
///
/// Implementations request their native compositor or display scheduler only
/// while the React runtime has animation work. The timestamp uses the host's
/// monotonic nanosecond domain.
@MainActor
public protocol NucleusPresentationFrameSource: AnyObject, Sendable {
    func requestPresentationFrame(
        _ completion: @escaping @MainActor @Sendable (UInt64) -> Void
    ) throws

    func cancelPresentationFrame()
}

/// A lifecycle-controlled relay between presentation demand and an external
/// platform callback.
///
/// Embedded hosts use this when their framework, rather than Swift, owns the
/// native frame-callback object. Surface and lifecycle transitions synchronously
/// release any retained completion before the external owner tears down.
@MainActor
package final class NucleusPresentationFrameRelay:
    NucleusPresentationFrameSource
{
    package enum RequestError: Error, Equatable {
        case inactive
        case surfaceUnavailable
        case requestOutstanding
    }

    private var active = false
    private var surfaceAvailable = false
    private var completion: (@MainActor @Sendable (UInt64) -> Void)?

    package init() {}

    package var hasOutstandingRequest: Bool { completion != nil }

    package func start() {
        active = true
    }

    package func stop() {
        active = false
        cancelPresentationFrame()
    }

    package func attachSurface() {
        // Attaching while a surface is already available is replacement. The
        // previous surface cannot remain the owner of a retained callback.
        cancelPresentationFrame()
        surfaceAvailable = true
    }

    package func detachSurface() {
        surfaceAvailable = false
        cancelPresentationFrame()
    }

    package func requestPresentationFrame(
        _ completion: @escaping @MainActor @Sendable (UInt64) -> Void
    ) throws {
        guard active else { throw RequestError.inactive }
        guard surfaceAvailable else { throw RequestError.surfaceUnavailable }
        guard self.completion == nil else {
            throw RequestError.requestOutstanding
        }
        self.completion = completion
    }

    package func cancelPresentationFrame() {
        completion = nil
    }

    package func deliver(frameTimeNanoseconds: Int64) {
        guard active, surfaceAvailable, let completion else { return }
        self.completion = nil
        completion(UInt64(max(0, frameTimeNanoseconds)))
    }
}
