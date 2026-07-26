import WaylandServer

extension WaylandResourceReference where Interface == WlBufferServer {
    public var shmMetadata: WaylandShmMetadata? {
        _shmMetadata
    }

    public func withShmBytes<Result: ~Copyable>(
        _ body: (
            WaylandShmMetadata,
            borrowing WaylandShmBytes
        ) -> Result
    ) throws(WaylandShmAccessError) -> Result {
        try _withShmBytes(body)
    }

    public func withMutableShmBytes<Result: ~Copyable>(
        _ body: (
            WaylandShmMetadata,
            borrowing MutableWaylandShmBytes
        ) -> Result
    ) throws(WaylandShmAccessError) -> Result {
        try _withMutableShmBytes(body)
    }
}
