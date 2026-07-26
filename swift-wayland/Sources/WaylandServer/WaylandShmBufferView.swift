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

public enum WaylandShmAccessError: Error, Equatable, Sendable {
    case notShmBuffer
    case invalidMetadata
    case dataUnavailable
}

/// A read-only byte view scoped to one `wl_shm_buffer_begin_access` interval.
///
/// Checked operations keep libwayland's mapped pointer inside this module.
/// Native consumers can opt into `withUnsafeBytes` at their own explicit
/// boundary without extending the mapping lifetime.
@safe public struct WaylandShmBytes: ~Escapable {
    @unsafe private let bytes: UnsafeRawBufferPointer

    @_lifetime(borrow bytes)
    @unsafe package init(_ bytes: borrowing UnsafeRawBufferPointer) {
        unsafe self.bytes = copy bytes
    }

    public var count: Int {
        unsafe bytes.count
    }

    public var isEmpty: Bool {
        count == 0
    }

    public subscript(index: Int) -> UInt8 {
        precondition(indices.contains(index), "SHM byte index is out of bounds")
        return unsafe bytes[index]
    }

    public var indices: Range<Int> {
        0..<count
    }

    public func copiedBytes() -> [UInt8] {
        unsafe Array(bytes)
    }

    /// Copy strided source rows into a tightly packed Swift array.
    public func copiedRows(
        rowBytes: Int,
        rowCount: Int,
        sourceStride: Int
    ) -> [UInt8]? {
        guard rowBytes >= 0,
            rowCount >= 0,
            sourceStride >= rowBytes
        else { return nil }
        let (outputCount, outputOverflow) =
            rowBytes.multipliedReportingOverflow(by: rowCount)
        guard !outputOverflow else { return nil }
        if rowCount > 0 {
            let (lastOffset, offsetOverflow) =
                (rowCount - 1).multipliedReportingOverflow(by: sourceStride)
            guard !offsetOverflow,
                rowBytes <= count,
                lastOffset <= count - rowBytes
            else { return nil }
        }

        var output = [UInt8](repeating: 0, count: outputCount)
        output.withUnsafeMutableBytes { destination in
            guard let sourceBase = unsafe bytes.baseAddress,
                let destinationBase = destination.baseAddress
            else { return }
            for row in 0..<rowCount {
                unsafe destinationBase.advanced(by: row * rowBytes)
                    .copyMemory(
                        from: sourceBase.advanced(by: row * sourceStride),
                        byteCount: rowBytes)
            }
        }
        return output
    }

    @unsafe
    public func withUnsafeBytes<Result: ~Copyable, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try unsafe body(bytes)
    }
}

/// A mutable byte view scoped to one `wl_shm_buffer_begin_access` interval.
@safe public struct MutableWaylandShmBytes: ~Escapable {
    @unsafe private var bytes: UnsafeMutableRawBufferPointer

    @_lifetime(borrow bytes)
    @unsafe package init(
        _ bytes: borrowing UnsafeMutableRawBufferPointer
    ) {
        unsafe self.bytes = copy bytes
    }

    public var count: Int {
        unsafe bytes.count
    }

    public var isEmpty: Bool {
        count == 0
    }

    public subscript(index: Int) -> UInt8 {
        get {
            precondition(indices.contains(index), "SHM byte index is out of bounds")
            return unsafe bytes[index]
        }
        nonmutating set {
            precondition(indices.contains(index), "SHM byte index is out of bounds")
            unsafe bytes[index] = newValue
        }
    }

    public var indices: Range<Int> {
        0..<count
    }

    /// Copy rows from an owned Swift byte array into this strided SHM mapping.
    public func copyRows(
        from source: [UInt8],
        sourceOffset: Int,
        sourceStride: Int,
        destinationOffset: Int = 0,
        destinationStride: Int,
        rowBytes: Int,
        rowCount: Int
    ) -> Bool {
        guard sourceOffset >= 0,
            sourceStride >= rowBytes,
            destinationOffset >= 0,
            destinationStride >= rowBytes,
            rowBytes >= 0,
            rowCount >= 0
        else { return false }
        if rowCount > 0 {
            let sourceDelta =
                (rowCount - 1).multipliedReportingOverflow(by: sourceStride)
            let destinationDelta =
                (rowCount - 1).multipliedReportingOverflow(
                    by: destinationStride)
            guard !sourceDelta.overflow,
                !destinationDelta.overflow
            else { return false }
            let sourceLast = sourceOffset.addingReportingOverflow(
                sourceDelta.partialValue)
            let destinationLast = destinationOffset.addingReportingOverflow(
                destinationDelta.partialValue)
            guard !sourceLast.overflow,
                !destinationLast.overflow,
                rowBytes <= source.count,
                rowBytes <= count,
                sourceLast.partialValue <= source.count - rowBytes,
                destinationLast.partialValue <= count - rowBytes
            else { return false }
        }

        source.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress,
                let destinationBase = unsafe bytes.baseAddress
            else { return }
            for row in 0..<rowCount {
                unsafe destinationBase
                    .advanced(by: destinationOffset + row * destinationStride)
                    .copyMemory(
                        from: sourceBase.advanced(
                            by: sourceOffset + row * sourceStride),
                        byteCount: rowBytes)
            }
        }
        return true
    }

    @unsafe
    public func withUnsafeMutableBytes<Result: ~Copyable, Failure: Error>(
        _ body: (UnsafeMutableRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try unsafe body(bytes)
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

    package func _withShmBytes<Result: ~Copyable>(
        _ body: (
            WaylandShmMetadata,
            borrowing WaylandShmBytes
        ) -> Result
    ) throws(WaylandShmAccessError) -> Result {
        guard let resource = unsafe nativeResource,
            let shm = unsafe wl_shm_buffer_get(resource)
        else { throw .notShmBuffer }
        guard let metadata = _shmMetadata else {
            throw .invalidMetadata
        }
        unsafe wl_shm_buffer_begin_access(shm)
        defer { unsafe wl_shm_buffer_end_access(shm) }
        guard let data = unsafe wl_shm_buffer_get_data(shm) else {
            throw .dataUnavailable
        }
        return unsafe body(
            metadata,
            WaylandShmBytes(UnsafeRawBufferPointer(
                start: data,
                count: metadata.byteCount)))
    }

    package func _withMutableShmBytes<Result: ~Copyable>(
        _ body: (
            WaylandShmMetadata,
            borrowing MutableWaylandShmBytes
        ) -> Result
    ) throws(WaylandShmAccessError) -> Result {
        guard let resource = unsafe nativeResource,
            let shm = unsafe wl_shm_buffer_get(resource)
        else { throw .notShmBuffer }
        guard let metadata = _shmMetadata else {
            throw .invalidMetadata
        }
        unsafe wl_shm_buffer_begin_access(shm)
        defer { unsafe wl_shm_buffer_end_access(shm) }
        guard let data = unsafe wl_shm_buffer_get_data(shm) else {
            throw .dataUnavailable
        }
        return unsafe body(
            metadata,
            MutableWaylandShmBytes(UnsafeMutableRawBufferPointer(
                start: data,
                count: metadata.byteCount)))
    }
}
