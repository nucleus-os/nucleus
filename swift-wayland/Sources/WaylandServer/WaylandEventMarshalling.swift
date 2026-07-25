package import WaylandServerC

@MainActor
@unsafe
package func withWaylandEventCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let value else { return body(nil) }
    return value.withCString(body)
}

@MainActor
@unsafe
package func withWaylandEventArray<Element, Result>(
    _ elements: [Element],
    _ body: (UnsafeMutablePointer<wl_array>) -> Result
) -> Result {
    elements.withUnsafeBytes { bytes in
        var array = unsafe wl_array(
            size: bytes.count,
            alloc: bytes.count,
            data: UnsafeMutableRawPointer(mutating: bytes.baseAddress))
        return unsafe body(&array)
    }
}
