import WaylandServerC

protocol WaylandProtocolErrorCode: RawRepresentable
where RawValue == UInt32 {}

struct WaylandProtocolError<Code: WaylandProtocolErrorCode> {
    let resource: UnsafeMutablePointer<wl_resource>
    let code: Code
    let diagnostic: String

    init(
        _ resource: UnsafeMutablePointer<wl_resource>,
        _ code: Code,
        _ diagnostic: String
    ) {
        self.resource = resource
        self.code = code
        self.diagnostic = diagnostic
    }

    func post() {
        swift_wayland_resource_post_error(
            resource, code.rawValue, diagnostic)
    }
}

enum XdgToplevelProtocolError: UInt32, WaylandProtocolErrorCode {
    case invalidResizeEdge = 0
    case invalidParent = 1
    case invalidSize = 2
}
