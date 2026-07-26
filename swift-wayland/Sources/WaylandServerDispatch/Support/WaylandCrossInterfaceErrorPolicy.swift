import WaylandServer
import WaylandProtocolTypes

public extension WaylandRequest
where Interface == ZxdgDecorationManagerV1Server {
    func postToplevelDecorationAlreadyConstructedError(
        message: String
    ) {
        postError(
            code: ZxdgToplevelDecorationV1Error.alreadyConstructed.rawValue,
            message: message)
    }
}

public extension WaylandResourceHandle
where Interface == ZxdgDecorationManagerV1Server {
    @discardableResult
    func postToplevelDecorationAlreadyConstructedError(
        message: String
    ) -> Bool {
        postError(
            code: ZxdgToplevelDecorationV1Error.alreadyConstructed.rawValue,
            message: message)
    }
}

public extension WaylandRequest
where Interface == ZwlrLayerSurfaceV1Server {
    func postLayerShellInvalidLayerError(message: String) {
        postError(
            code: ZwlrLayerShellV1Error.invalidLayer.rawValue,
            message: message)
    }
}

public extension WaylandResourceHandle
where Interface == ZwlrLayerSurfaceV1Server {
    @discardableResult
    func postLayerShellInvalidLayerError(message: String) -> Bool {
        postError(
            code: ZwlrLayerShellV1Error.invalidLayer.rawValue,
            message: message)
    }
}
