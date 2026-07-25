#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Move-only ownership of a file descriptor transferred by a Wayland request.
///
/// The descriptor closes automatically unless ownership is explicitly taken.
@MainActor
@safe public struct WaylandOwnedFileDescriptor: ~Copyable {
    private var descriptor: Int32

    package init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    public var rawValue: Int32 {
        descriptor
    }

    public consuming func take() -> Int32 {
        let result = descriptor
        descriptor = -1
        return result
    }

    deinit {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }
}
