import WaylandProtocolTypes
import WaylandServer

extension WaylandRequest
where Interface == ZxdgDecorationManagerV1Server {
    package func postToplevelDecorationAlreadyConstructedError(
        message: String
    ) {
        postError(
            code: ZxdgToplevelDecorationV1Error.alreadyConstructed.rawValue,
            message: message)
    }
}

extension WaylandResourceHandle
where Interface == ZxdgDecorationManagerV1Server {
    @discardableResult
    package func postToplevelDecorationAlreadyConstructedError(
        message: String
    ) -> Bool {
        postError(
            code: ZxdgToplevelDecorationV1Error.alreadyConstructed.rawValue,
            message: message)
    }
}

extension WaylandRequest
where Interface == ZwlrLayerSurfaceV1Server {
    package func postLayerShellInvalidLayerError(message: String) {
        postError(
            code: ZwlrLayerShellV1Error.invalidLayer.rawValue,
            message: message)
    }
}

extension WaylandResourceHandle
where Interface == ZwlrLayerSurfaceV1Server {
    @discardableResult
    package func postLayerShellInvalidLayerError(message: String) -> Bool {
        postError(
            code: ZwlrLayerShellV1Error.invalidLayer.rawValue,
            message: message)
    }
}
