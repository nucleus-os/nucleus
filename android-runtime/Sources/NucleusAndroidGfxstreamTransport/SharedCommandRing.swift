import Foundation
import Glibc
import NucleusAndroidSharedRingC
import Synchronization

package enum GfxstreamTransportError: Error, Equatable, Sendable {
    case createFailed(errno: Int32)
    case attachFailed(errno: Int32)
    case exportFailed(errno: Int32)
    case duplicateEndpointRole
    case full
    case empty
    case closed
    case packetTooLarge
    case receiveBufferTooSmall
    case systemCall(errno: Int32)
}

package enum SharedCommandRingWaitPreparation: Sendable, Equatable {
    case ready
    case armed
    case closed
}

package struct SharedCommandRingDiagnostic: Sendable, Equatable {
    package let writeBackpressureCount: UInt64
    package let readEmptyCount: UInt64
    package let maximumOccupancy: UInt64
    package let dataNotificationWriteCount: UInt64
    package let dataNotificationDrainCount: UInt64
    package let spaceNotificationWriteCount: UInt64
    package let spaceNotificationDrainCount: UInt64
    package let isClosed: Bool
}

/// Owns shared-memory and notification descriptors without producer or
/// consumer authority. A mapping only wires directional endpoints and exposes
/// ring-wide diagnostics.
@safe package final class SharedCommandRingMapping {
    private let handle: OpaquePointer
    package let slotCount: UInt32
    package let slotSize: UInt32

    package init(
        slotCount: UInt32 = 256,
        slotSize: UInt32 = 64 * 1024
    ) throws {
        guard
            let handle = unsafe nucleus_android_shared_ring_mapping_create(
                slotCount,
                slotSize)
        else {
            let capturedErrno = errno
            throw GfxstreamTransportError.createFailed(
                errno: capturedErrno)
        }
        unsafe self.handle = handle
        self.slotCount = slotCount
        self.slotSize = slotSize
    }

    package func exportFileDescriptors() throws -> (
        memory: Int32,
        dataNotification: Int32,
        spaceNotification: Int32
    ) {
        var descriptors = nucleus_android_shared_ring_descriptors(
            memory_fd: -1,
            data_notification_fd: -1,
            space_notification_fd: -1)
        let result = unsafe nucleus_android_shared_ring_mapping_export_descriptors(
            handle,
            &descriptors)
        let capturedErrno = errno
        guard result == 0 else {
            throw GfxstreamTransportError.exportFailed(
                errno: capturedErrno)
        }
        return (
            descriptors.memory_fd,
            descriptors.data_notification_fd,
            descriptors.space_notification_fd
        )
    }

    package func makeProducer() throws -> SharedCommandProducer {
        let descriptors = try exportFileDescriptors()
        return try SharedCommandProducer(
            owningMemoryFD: descriptors.memory,
            dataNotificationFD: descriptors.dataNotification,
            spaceNotificationFD: descriptors.spaceNotification)
    }

    package func makeConsumer() throws -> SharedCommandConsumer {
        let descriptors = try exportFileDescriptors()
        return try SharedCommandConsumer(
            owningMemoryFD: descriptors.memory,
            dataNotificationFD: descriptors.dataNotification,
            spaceNotificationFD: descriptors.spaceNotification)
    }

    package func close() throws {
        let result = unsafe nucleus_android_shared_ring_mapping_close(handle)
        let capturedErrno = errno
        guard result == 0 else {
            throw GfxstreamTransportError.systemCall(
                errno: capturedErrno)
        }
    }

    package var diagnostic: SharedCommandRingDiagnostic {
        get throws {
            var value = nucleus_android_shared_ring_diagnostic()
            let result =
                unsafe nucleus_android_shared_ring_mapping_get_diagnostic(
                    handle,
                    &value)
            let capturedErrno = errno
            guard result == 0 else {
                throw GfxstreamTransportError.systemCall(
                    errno: capturedErrno)
            }
            return SharedCommandRingDiagnostic(value)
        }
    }

    deinit {
        unsafe nucleus_android_shared_ring_mapping_destroy(handle)
    }
}

@safe package final class SharedCommandProducer: Sendable {
    private let handle: Mutex<OpaquePointer>
    package let slotCount: UInt32
    package let slotSize: UInt32

    package init(
        owningMemoryFD memoryFD: Int32,
        dataNotificationFD: Int32,
        spaceNotificationFD: Int32
    ) throws {
        let descriptors = nucleus_android_shared_ring_descriptors(
            memory_fd: memoryFD,
            data_notification_fd: dataNotificationFD,
            space_notification_fd: spaceNotificationFD)
        guard
            let handle = unsafe nucleus_android_shared_ring_producer_attach(
                descriptors)
        else {
            let capturedErrno = errno
            if capturedErrno == EBUSY {
                throw GfxstreamTransportError.duplicateEndpointRole
            }
            throw GfxstreamTransportError.attachFailed(
                errno: capturedErrno)
        }
        slotCount =
            unsafe nucleus_android_shared_ring_producer_slot_count(handle)
        slotSize =
            unsafe nucleus_android_shared_ring_producer_slot_size(handle)
        unsafe self.handle = Mutex(handle)
    }

    package var spaceNotificationFileDescriptor: Int32 {
        unsafe handle.withLock {
            unsafe nucleus_android_shared_ring_producer_space_notification_fd($0)
        }
    }

    package func write(_ packet: Data) throws {
        let payloadCapacity =
            Int(slotSize) - MemoryLayout<UInt32>.size
        guard packet.count <= payloadCapacity else {
            throw GfxstreamTransportError.packetTooLarge
        }
        try unsafe handle.withLock { handle in
            let (result, capturedErrno) = unsafe packet.withUnsafeBytes { bytes in
                let result = unsafe nucleus_android_shared_ring_producer_write(
                    handle,
                    bytes.baseAddress,
                    UInt32(bytes.count))
                return (result, errno)
            }
            guard result == 0 else {
                switch capturedErrno {
                case EAGAIN:
                    throw GfxstreamTransportError.full
                case EPIPE:
                    throw GfxstreamTransportError.closed
                case EMSGSIZE:
                    throw GfxstreamTransportError.packetTooLarge
                default:
                    throw GfxstreamTransportError.systemCall(
                        errno: capturedErrno)
                }
            }
        }
    }

    package func prepareSpaceWait()
        throws -> SharedCommandRingWaitPreparation
    {
        try unsafe handle.withLock { handle in
            let result =
                unsafe nucleus_android_shared_ring_producer_prepare_space_wait(
                    handle)
            let capturedErrno = errno
            return try decodeWaitPreparation(
                result,
                errno: capturedErrno)
        }
    }

    package func drainSpaceNotification() throws {
        try unsafe handle.withLock { handle in
            let result =
                unsafe nucleus_android_shared_ring_producer_drain_space_notification(
                    handle)
            let capturedErrno = errno
            guard result == 0 else {
                throw GfxstreamTransportError.systemCall(
                    errno: capturedErrno)
            }
        }
    }

    package func close() throws {
        try unsafe handle.withLock { handle in
            let result =
                unsafe nucleus_android_shared_ring_producer_close(handle)
            let capturedErrno = errno
            guard result == 0 else {
                throw GfxstreamTransportError.systemCall(
                    errno: capturedErrno)
            }
        }
    }

    package var diagnostic: SharedCommandRingDiagnostic {
        get throws {
            try unsafe handle.withLock { handle in
                var value = nucleus_android_shared_ring_diagnostic()
                let result =
                    unsafe nucleus_android_shared_ring_producer_get_diagnostic(
                        handle,
                        &value)
                let capturedErrno = errno
                guard result == 0 else {
                    throw GfxstreamTransportError.systemCall(
                        errno: capturedErrno)
                }
                return SharedCommandRingDiagnostic(value)
            }
        }
    }

    deinit {
        unsafe handle.withLock {
            unsafe nucleus_android_shared_ring_producer_destroy($0)
        }
    }
}

@safe package final class SharedCommandConsumer: Sendable {
    private let handle: Mutex<OpaquePointer>
    package let slotCount: UInt32
    package let slotSize: UInt32

    package init(
        owningMemoryFD memoryFD: Int32,
        dataNotificationFD: Int32,
        spaceNotificationFD: Int32
    ) throws {
        let descriptors = nucleus_android_shared_ring_descriptors(
            memory_fd: memoryFD,
            data_notification_fd: dataNotificationFD,
            space_notification_fd: spaceNotificationFD)
        guard
            let handle = unsafe nucleus_android_shared_ring_consumer_attach(
                descriptors)
        else {
            let capturedErrno = errno
            if capturedErrno == EBUSY {
                throw GfxstreamTransportError.duplicateEndpointRole
            }
            throw GfxstreamTransportError.attachFailed(
                errno: capturedErrno)
        }
        slotCount =
            unsafe nucleus_android_shared_ring_consumer_slot_count(handle)
        slotSize =
            unsafe nucleus_android_shared_ring_consumer_slot_size(handle)
        unsafe self.handle = Mutex(handle)
    }

    package var dataNotificationFileDescriptor: Int32 {
        unsafe handle.withLock {
            unsafe nucleus_android_shared_ring_consumer_data_notification_fd($0)
        }
    }

    package func read() throws -> Data {
        let payloadCapacity =
            Int(slotSize) - MemoryLayout<UInt32>.size
        return try unsafe handle.withLock { handle in
            guard let storage = unsafe malloc(payloadCapacity) else {
                throw GfxstreamTransportError.systemCall(errno: ENOMEM)
            }
            let result = unsafe nucleus_android_shared_ring_consumer_read(
                handle,
                storage,
                UInt32(payloadCapacity))
            let capturedErrno = errno
            guard result >= 0 else {
                unsafe free(storage)
                switch capturedErrno {
                case EAGAIN:
                    throw GfxstreamTransportError.empty
                case EPIPE:
                    throw GfxstreamTransportError.closed
                case EMSGSIZE:
                    throw GfxstreamTransportError.receiveBufferTooSmall
                default:
                    throw GfxstreamTransportError.systemCall(
                        errno: capturedErrno)
                }
            }
            return unsafe Data(
                bytesNoCopy: storage,
                count: Int(result),
                deallocator: .free)
        }
    }

    package func prepareDataWait()
        throws -> SharedCommandRingWaitPreparation
    {
        try unsafe handle.withLock { handle in
            let result =
                unsafe nucleus_android_shared_ring_consumer_prepare_data_wait(
                    handle)
            let capturedErrno = errno
            return try decodeWaitPreparation(
                result,
                errno: capturedErrno)
        }
    }

    package func drainDataNotification() throws {
        try unsafe handle.withLock { handle in
            let result =
                unsafe nucleus_android_shared_ring_consumer_drain_data_notification(
                    handle)
            let capturedErrno = errno
            guard result == 0 else {
                throw GfxstreamTransportError.systemCall(
                    errno: capturedErrno)
            }
        }
    }

    package func close() throws {
        try unsafe handle.withLock { handle in
            let result =
                unsafe nucleus_android_shared_ring_consumer_close(handle)
            let capturedErrno = errno
            guard result == 0 else {
                throw GfxstreamTransportError.systemCall(
                    errno: capturedErrno)
            }
        }
    }

    package var diagnostic: SharedCommandRingDiagnostic {
        get throws {
            try unsafe handle.withLock { handle in
                var value = nucleus_android_shared_ring_diagnostic()
                let result =
                    unsafe nucleus_android_shared_ring_consumer_get_diagnostic(
                        handle,
                        &value)
                let capturedErrno = errno
                guard result == 0 else {
                    throw GfxstreamTransportError.systemCall(
                        errno: capturedErrno)
                }
                return SharedCommandRingDiagnostic(value)
            }
        }
    }

    deinit {
        unsafe handle.withLock {
            unsafe nucleus_android_shared_ring_consumer_destroy($0)
        }
    }
}

package struct GfxstreamGuestDuplexEndpoint: Sendable {
    package let commandProducer: SharedCommandProducer
    package let responseConsumer: SharedCommandConsumer

    package init(
        commandProducer: SharedCommandProducer,
        responseConsumer: SharedCommandConsumer
    ) {
        self.commandProducer = commandProducer
        self.responseConsumer = responseConsumer
    }
}

package struct GfxstreamHostDuplexEndpoint: Sendable {
    package let commandConsumer: SharedCommandConsumer
    package let responseProducer: SharedCommandProducer

    package init(
        commandConsumer: SharedCommandConsumer,
        responseProducer: SharedCommandProducer
    ) {
        self.commandConsumer = commandConsumer
        self.responseProducer = responseProducer
    }
}

package enum GfxstreamDuplexTransport {
    package static func makePair(
        slotCount: UInt32 = 256,
        slotSize: UInt32 = 64 * 1024
    ) throws -> (
        guest: GfxstreamGuestDuplexEndpoint,
        host: GfxstreamHostDuplexEndpoint
    ) {
        let commands = try SharedCommandRingMapping(
            slotCount: slotCount,
            slotSize: slotSize)
        let responses = try SharedCommandRingMapping(
            slotCount: slotCount,
            slotSize: slotSize)
        let commandProducer = try commands.makeProducer()
        let commandConsumer = try commands.makeConsumer()
        let responseProducer = try responses.makeProducer()
        let responseConsumer = try responses.makeConsumer()
        return (
            guest: GfxstreamGuestDuplexEndpoint(
                commandProducer: commandProducer,
                responseConsumer: responseConsumer),
            host: GfxstreamHostDuplexEndpoint(
                commandConsumer: commandConsumer,
                responseProducer: responseProducer)
        )
    }
}

private func decodeWaitPreparation(
    _ result: nucleus_android_shared_ring_wait_result,
    errno capturedErrno: Int32
) throws -> SharedCommandRingWaitPreparation {
    switch result {
    case NUCLEUS_ANDROID_SHARED_RING_WAIT_READY:
        return .ready
    case NUCLEUS_ANDROID_SHARED_RING_WAIT_ARMED:
        return .armed
    case NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED:
        return .closed
    default:
        throw GfxstreamTransportError.systemCall(errno: capturedErrno)
    }
}

extension SharedCommandRingDiagnostic {
    fileprivate init(_ value: nucleus_android_shared_ring_diagnostic) {
        writeBackpressureCount = value.write_backpressure_count
        readEmptyCount = value.read_empty_count
        maximumOccupancy = value.maximum_occupancy
        dataNotificationWriteCount =
            value.data_notification_write_count
        dataNotificationDrainCount =
            value.data_notification_drain_count
        spaceNotificationWriteCount =
            value.space_notification_write_count
        spaceNotificationDrainCount =
            value.space_notification_drain_count
        isClosed = value.closed != 0
    }
}
