import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
import WaylandClientDispatch
import WaylandProtocolTypes

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
        return unsafe data.withUnsafeBytes { bytes in
            return stride(from: 0, to: bytes.count, by: 16).map { offset in
                let format = unsafe bytes.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self)
                let modifier = unsafe bytes.loadUnaligned(
                    fromByteOffset: offset + 8,
                    as: UInt64.self)
                return DrmFormatModifier(
                    format: format,
                    modifier: modifier)
            }
        }
    }
}

@safe private final class ReadOnlyFileMapping {
    @unsafe private let address: UnsafeMutableRawPointer
    let byteCount: Int

    init?(fileDescriptor: Int32, byteCount: Int) {
        guard byteCount > 0 else { return nil }
        let result = unsafe mmap(
            nil, byteCount, PROT_READ, MAP_PRIVATE, fileDescriptor, 0)
        guard let address = unsafe result,
            unsafe address != MAP_FAILED
        else { return nil }
        unsafe self.address = address
        self.byteCount = byteCount
    }

    func copiedData() -> Data {
        unsafe Data(bytes: address, count: byteCount)
    }

    deinit {
        _ = unsafe munmap(address, byteCount)
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

    func done(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>
    ) {
        do { feedback = try accumulator.finish() } catch { failure = error }
    }

    func formatTable(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        fd: consuming WaylandClientOwnedFileDescriptor,
        size: UInt32
    ) {
        let descriptor = fd.take()
        defer { _ = close(descriptor) }
        guard size > 0 else {
            failure = SurfaceProbeError.invalidFormatTable
            return
        }
        guard let mapping = ReadOnlyFileMapping(
            fileDescriptor: descriptor,
            byteCount: Int(size))
        else {
            failure = SurfaceProbeError.invalidFormatTable
            return
        }
        do {
            try accumulator.setFormatTable(mapping.copiedData())
        } catch { failure = error }
    }

    func mainDevice(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        device: WaylandClientArrayView
    ) {
        consumeDevice(device, accumulator.setMainDevice)
    }

    func trancheDone(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>
    ) {
        do { try accumulator.finishTranche() } catch { failure = error }
    }

    func trancheTargetDevice(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        device: WaylandClientArrayView
    ) {
        consumeDevice(device, accumulator.setTargetDevice)
    }

    func trancheFormats(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        indices: WaylandClientArrayView
    ) {
        guard let values = indices.copiedElements(of: UInt16.self) else {
            failure = SurfaceProbeError.invalidTranche
            return
        }
        accumulator.setIndices(values)
    }

    func trancheFlags(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        flags: ZwpLinuxDmabufFeedbackV1TrancheFlags
    ) {
        accumulator.setFlags(flags.rawValue)
    }

    private func consumeDevice(
        _ array: WaylandClientArrayView,
        _ consume: (GraphicsDeviceID) -> Void
    ) {
        var raw = nucleus_android_device_id()
        let result = unsafe array.withUnsafeBytes { bytes in
            unsafe nucleus_android_drm_device_id_from_native(
                bytes.baseAddress,
                bytes.count,
                &raw)
        }
        guard result == 0 else {
            failure = SurfaceProbeError.invalidDeviceIdentity
            return
        }
        consume(GraphicsDeviceID(major: raw.major, minor: raw.minor))
    }
}
