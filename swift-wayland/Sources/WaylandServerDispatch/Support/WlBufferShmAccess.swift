import WaylandServer

extension WaylandResourceReference where Interface == WlBufferServer {
    public var shmMetadata: WaylandShmMetadata? {
        _shmMetadata
    }

    public func withShmBytes<Result>(
        _ body: (
            WaylandShmMetadata,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result? {
        try unsafe _withShmBytes(body)
    }

    public func withMutableShmBytes<Result>(
        _ body: (
            WaylandShmMetadata,
            UnsafeMutableRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result? {
        try unsafe _withMutableShmBytes(body)
    }
}
