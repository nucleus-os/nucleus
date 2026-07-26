import WaylandServerC

public struct WaylandShmMetadata: Equatable, Sendable {
    public let format: UInt32
    public let width: Int
    public let height: Int
    public let stride: Int
    public let byteCount: Int

    public init(
        format: UInt32,
        width: Int,
        height: Int,
        stride: Int,
        byteCount: Int
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.stride = stride
        self.byteCount = byteCount
    }

    package init?(
        format: UInt32,
        width: Int32,
        height: Int32,
        stride: Int32
    ) {
        guard width > 0, height > 0, stride >= 0 else {
            return nil
        }
        let (byteCount, overflow) =
            Int(stride).multipliedReportingOverflow(by: Int(height))
        guard !overflow else { return nil }
        self.init(
            format: format,
            width: Int(width),
            height: Int(height),
            stride: Int(stride),
            byteCount: byteCount)
    }
}

extension WaylandResourceReference {
    package var _shmMetadata: WaylandShmMetadata? {
        guard let resource = unsafe nativeResource,
            let shm = unsafe wl_shm_buffer_get(resource)
        else { return nil }
        return WaylandShmMetadata(
            format: unsafe wl_shm_buffer_get_format(shm),
            width: unsafe wl_shm_buffer_get_width(shm),
            height: unsafe wl_shm_buffer_get_height(shm),
            stride: unsafe wl_shm_buffer_get_stride(shm))
    }

    package func _withShmBytes<Result>(
        _ body: (
            WaylandShmMetadata,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result? {
        guard let resource = unsafe nativeResource,
            let shm = unsafe wl_shm_buffer_get(resource),
            let metadata = unsafe _shmMetadata
        else { return nil }
        unsafe wl_shm_buffer_begin_access(shm)
        defer { unsafe wl_shm_buffer_end_access(shm) }
        guard let data = unsafe wl_shm_buffer_get_data(shm) else {
            return nil
        }
        return try unsafe body(
            metadata,
            UnsafeRawBufferPointer(
                start: data,
                count: metadata.byteCount))
    }

    package func _withMutableShmBytes<Result>(
        _ body: (
            WaylandShmMetadata,
            UnsafeMutableRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result? {
        guard let resource = unsafe nativeResource,
            let shm = unsafe wl_shm_buffer_get(resource),
            let metadata = unsafe _shmMetadata
        else { return nil }
        unsafe wl_shm_buffer_begin_access(shm)
        defer { unsafe wl_shm_buffer_end_access(shm) }
        guard let data = unsafe wl_shm_buffer_get_data(shm) else {
            return nil
        }
        return try unsafe body(
            metadata,
            UnsafeMutableRawBufferPointer(
                start: data,
                count: metadata.byteCount))
    }
}
