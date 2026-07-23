import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
import WaylandClientC
import WaylandClientDispatch

public enum SurfaceProbeError: Error, Equatable, Sendable {
    case waylandConnectionFailed
    case missingGlobal(String)
    case roundtripFailed
    case invalidFormatTable
    case invalidDeviceIdentity
    case invalidTranche
    case incompleteFeedback
    case brokerFailure(GraphicsFailure)
    case invalidBrokerReply
    case waylandObjectCreationFailed(String)
    case compositorClosed
    case eventTimeout
    case reactorFailure(Int32)
}

public enum DmabufFeedbackTable {
    public static func decode(_ data: Data) throws -> [DrmFormatModifier] {
        guard !data.isEmpty, data.count % 16 == 0 else {
            throw SurfaceProbeError.invalidFormatTable
        }
        return try data.withUnsafeBytes { bytes in
            guard bytes.baseAddress != nil else {
                throw SurfaceProbeError.invalidFormatTable
            }
            return stride(from: 0, to: bytes.count, by: 16).map { offset in
                DrmFormatModifier(
                    format: bytes.loadUnaligned(
                        fromByteOffset: offset,
                        as: UInt32.self),
                    modifier: bytes.loadUnaligned(
                        fromByteOffset: offset + 8,
                        as: UInt64.self))
            }
        }
    }
}

final class DmabufFeedbackAccumulator {
    private(set) var table: [DrmFormatModifier] = []
    private(set) var mainDevice: GraphicsDeviceID?
    private(set) var tranches: [WaylandDmabufTranche] = []
    private var targetDevice: GraphicsDeviceID?
    private var indices: [UInt16] = []
    private var scanout = false

    func setFormatTable(_ data: Data) throws {
        table = try DmabufFeedbackTable.decode(data)
    }

    func setMainDevice(_ value: GraphicsDeviceID) {
        mainDevice = value
    }

    func setTargetDevice(_ value: GraphicsDeviceID) {
        targetDevice = value
    }

    func setIndices(_ values: [UInt16]) {
        indices = values
    }

    func setFlags(_ value: UInt32) {
        scanout = (value & 1) != 0
    }

    func finishTranche() throws {
        guard let targetDevice, !indices.isEmpty,
              indices.allSatisfy({ Int($0) < table.count })
        else { throw SurfaceProbeError.invalidTranche }
        tranches.append(WaylandDmabufTranche(
            targetDevice: targetDevice,
            scanout: scanout,
            formats: indices.map { table[Int($0)] }))
        self.targetDevice = nil
        indices = []
        scanout = false
    }

    func finish() throws -> WaylandDmabufFeedback {
        guard let mainDevice, !tranches.isEmpty else {
            throw SurfaceProbeError.incompleteFeedback
        }
        return WaylandDmabufFeedback(mainDevice: mainDevice, tranches: tranches)
    }
}

final class WaylandDmabufFeedbackCollector: ZwpLinuxDmabufFeedbackV1Events {
    private let accumulator = DmabufFeedbackAccumulator()
    private(set) var feedback: WaylandDmabufFeedback?
    private(set) var failure: Error?

    func done(_ proxy: OpaquePointer) {
        do { feedback = try accumulator.finish() } catch { failure = error }
    }

    func formatTable(_ proxy: OpaquePointer, fd: Int32, size: UInt32) {
        defer { _ = close(fd) }
        guard size > 0 else {
            failure = SurfaceProbeError.invalidFormatTable
            return
        }
        let mapping = mmap(nil, Int(size), PROT_READ, MAP_PRIVATE, fd, 0)
        guard mapping != MAP_FAILED, let mapping else {
            failure = SurfaceProbeError.invalidFormatTable
            return
        }
        defer { _ = munmap(mapping, Int(size)) }
        do {
            try accumulator.setFormatTable(Data(bytes: mapping, count: Int(size)))
        } catch { failure = error }
    }

    func mainDevice(_ proxy: OpaquePointer, device: UnsafeMutablePointer<wl_array>?) {
        consumeDevice(device, accumulator.setMainDevice)
    }

    func trancheDone(_ proxy: OpaquePointer) {
        do { try accumulator.finishTranche() } catch { failure = error }
    }

    func trancheTargetDevice(
        _ proxy: OpaquePointer,
        device: UnsafeMutablePointer<wl_array>?
    ) {
        consumeDevice(device, accumulator.setTargetDevice)
    }

    func trancheFormats(
        _ proxy: OpaquePointer,
        indices: UnsafeMutablePointer<wl_array>?
    ) {
        guard let indices, indices.pointee.size % MemoryLayout<UInt16>.size == 0,
              let data = indices.pointee.data
        else {
            failure = SurfaceProbeError.invalidTranche
            return
        }
        let count = indices.pointee.size / MemoryLayout<UInt16>.size
        accumulator.setIndices((0..<count).map { index in
            UnsafeRawPointer(data).loadUnaligned(
                fromByteOffset: index * MemoryLayout<UInt16>.size,
                as: UInt16.self)
        })
    }

    func trancheFlags(_ proxy: OpaquePointer, flags: UInt32) {
        accumulator.setFlags(flags)
    }

    private func consumeDevice(
        _ array: UnsafeMutablePointer<wl_array>?,
        _ consume: (GraphicsDeviceID) -> Void
    ) {
        guard let array, let bytes = array.pointee.data else {
            failure = SurfaceProbeError.invalidDeviceIdentity
            return
        }
        var raw = nucleus_android_device_id()
        guard nucleus_android_drm_device_id_from_native(
            bytes,
            array.pointee.size,
            &raw) == 0
        else {
            failure = SurfaceProbeError.invalidDeviceIdentity
            return
        }
        consume(GraphicsDeviceID(major: raw.major, minor: raw.minor))
    }
}
