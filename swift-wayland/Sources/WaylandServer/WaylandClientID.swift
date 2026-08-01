/// Opaque identity for one live libwayland client.
///
/// The value is suitable only for equality and hashing. It cannot be converted
/// back into a client pointer and grants no access to libwayland state.
package struct WaylandClientID: Hashable, Sendable {
    private let rawValue: UInt

    package var opaqueValue: UInt { rawValue }

    @unsafe
    package init?(_ client: OpaquePointer?) {
        guard let client = unsafe client else { return nil }
        rawValue = UInt(bitPattern: client)
    }
}
