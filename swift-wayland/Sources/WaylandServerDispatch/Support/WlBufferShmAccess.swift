import WaylandServer

extension WaylandResourceReference where Interface == WlBufferServer {
    package var shmMetadata: WaylandShmMetadata? {
        _shmMetadata
    }

    package func withShmBytes<Result: ~Copyable>(
        _ body: (
            WaylandShmMetadata,
            borrowing WaylandShmBytes
        ) -> Result
    ) throws(WaylandShmAccessError) -> Result {
        try _withShmBytes(body)
    }

    package func withMutableShmBytes<Result: ~Copyable>(
        _ body: (
            WaylandShmMetadata,
            borrowing MutableWaylandShmBytes
        ) -> Result
    ) throws(WaylandShmAccessError) -> Result {
        try _withMutableShmBytes(body)
    }
}
