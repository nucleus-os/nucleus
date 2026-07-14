import NucleusCompositorOverlayTypes

@usableFromInline
func stringView(_ value: NucleusCompositorOverlayTypes.StringView) -> String {
    guard let ptr = value.ptr, value.len > 0 else {
        return ""
    }
    let buffer = UnsafeBufferPointer(start: ptr, count: Int(value.len))
    return String(decoding: buffer, as: UTF8.self)
}
