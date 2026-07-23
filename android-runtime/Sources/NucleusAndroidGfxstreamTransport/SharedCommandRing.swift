import Foundation
import Glibc
import NucleusAndroidSharedRingC

public enum GfxstreamTransportError: Error, Equatable, Sendable {
    case createFailed(errno: Int32)
    case attachFailed(errno: Int32)
    case exportFailed(errno: Int32)
    case full
    case empty
    case packetTooLarge
    case receiveBufferTooSmall
    case systemCall(errno: Int32)
}

public final class SharedCommandRing: @unchecked Sendable {
    private let handle: OpaquePointer
    public let slotCount: UInt32
    public let slotSize: UInt32

    public init(slotCount: UInt32 = 256, slotSize: UInt32 = 64 * 1024) throws {
        guard let handle = nucleus_android_shared_ring_create(slotCount, slotSize) else {
            throw GfxstreamTransportError.createFailed(errno: errno)
        }
        self.handle = handle
        self.slotCount = nucleus_android_shared_ring_slot_count(handle)
        self.slotSize = nucleus_android_shared_ring_slot_size(handle)
    }

    public init(
        owningMemoryFD memoryFD: Int32,
        dataNotificationFD: Int32,
        spaceNotificationFD: Int32
    ) throws {
        guard let handle = nucleus_android_shared_ring_attach(
            memoryFD,
            dataNotificationFD,
            spaceNotificationFD)
        else {
            throw GfxstreamTransportError.attachFailed(errno: errno)
        }
        self.handle = handle
        slotCount = nucleus_android_shared_ring_slot_count(handle)
        slotSize = nucleus_android_shared_ring_slot_size(handle)
    }

    public var dataNotificationFileDescriptor: Int32 {
        nucleus_android_shared_ring_data_notification_fd(handle)
    }

    public var spaceNotificationFileDescriptor: Int32 {
        nucleus_android_shared_ring_space_notification_fd(handle)
    }

    public func exportFileDescriptors() throws -> (
        memory: Int32,
        dataNotification: Int32,
        spaceNotification: Int32
    ) {
        let memory = nucleus_android_shared_ring_export_memory_fd(handle)
        guard memory >= 0 else { throw GfxstreamTransportError.exportFailed(errno: errno) }
        let dataNotification = nucleus_android_shared_ring_export_data_notification_fd(handle)
        guard dataNotification >= 0 else {
            let saved = errno
            _ = close(memory)
            throw GfxstreamTransportError.exportFailed(errno: saved)
        }
        let spaceNotification = nucleus_android_shared_ring_export_space_notification_fd(handle)
        guard spaceNotification >= 0 else {
            let saved = errno
            _ = close(dataNotification)
            _ = close(memory)
            throw GfxstreamTransportError.exportFailed(errno: saved)
        }
        return (memory, dataNotification, spaceNotification)
    }

    public func write(_ packet: Data) throws {
        guard packet.count <= Int(slotSize) - MemoryLayout<UInt32>.size else {
            throw GfxstreamTransportError.packetTooLarge
        }
        let result = packet.withUnsafeBytes { bytes in
            nucleus_android_shared_ring_write(
                handle,
                bytes.baseAddress,
                UInt32(bytes.count))
        }
        guard result == 0 else {
            switch errno {
            case EAGAIN: throw GfxstreamTransportError.full
            case EMSGSIZE: throw GfxstreamTransportError.packetTooLarge
            default: throw GfxstreamTransportError.systemCall(errno: errno)
            }
        }
    }

    public func read() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Int(slotSize))
        let count = bytes.withUnsafeMutableBytes { buffer in
            nucleus_android_shared_ring_read(
                handle,
                buffer.baseAddress,
                UInt32(buffer.count))
        }
        guard count >= 0 else {
            switch errno {
            case EAGAIN: throw GfxstreamTransportError.empty
            case EMSGSIZE: throw GfxstreamTransportError.receiveBufferTooSmall
            default: throw GfxstreamTransportError.systemCall(errno: errno)
            }
        }
        return Data(bytes.prefix(Int(count)))
    }

    public func drainDataNotification() throws {
        guard nucleus_android_shared_ring_drain_data_notification(handle) == 0 else {
            throw GfxstreamTransportError.systemCall(errno: errno)
        }
    }

    public func drainSpaceNotification() throws {
        guard nucleus_android_shared_ring_drain_space_notification(handle) == 0 else {
            throw GfxstreamTransportError.systemCall(errno: errno)
        }
    }

    deinit { nucleus_android_shared_ring_destroy(handle) }
}

public struct GfxstreamDuplexEndpoint: Sendable {
    public let commands: SharedCommandRing
    public let responses: SharedCommandRing

    public init(commands: SharedCommandRing, responses: SharedCommandRing) {
        self.commands = commands
        self.responses = responses
    }

    public static func makePair(
        slotCount: UInt32 = 256,
        slotSize: UInt32 = 64 * 1024
    ) throws -> (guest: GfxstreamDuplexEndpoint, host: GfxstreamDuplexEndpoint) {
        let commandOwner = try SharedCommandRing(slotCount: slotCount, slotSize: slotSize)
        let responseOwner = try SharedCommandRing(slotCount: slotCount, slotSize: slotSize)
        let commandFDs = try commandOwner.exportFileDescriptors()
        let responseFDs = try responseOwner.exportFileDescriptors()
        let commandPeer = try SharedCommandRing(
            owningMemoryFD: commandFDs.memory,
            dataNotificationFD: commandFDs.dataNotification,
            spaceNotificationFD: commandFDs.spaceNotification)
        let responsePeer = try SharedCommandRing(
            owningMemoryFD: responseFDs.memory,
            dataNotificationFD: responseFDs.dataNotification,
            spaceNotificationFD: responseFDs.spaceNotification)
        return (
            guest: GfxstreamDuplexEndpoint(
                commands: commandOwner,
                responses: responsePeer),
            host: GfxstreamDuplexEndpoint(
                commands: commandPeer,
                responses: responseOwner))
    }
}
