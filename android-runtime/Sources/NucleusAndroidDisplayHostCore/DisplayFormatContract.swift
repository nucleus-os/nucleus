import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract
import NucleusAndroidGraphicsPlatform
import WaylandClient
import WaylandClientDispatch
import WaylandProtocolTypes

@MainActor
func validateDisplayFormatContract(
    connection: WaylandConnection,
    dmabuf: WaylandProxy<ZwpLinuxDmabufV1Client>,
    renderDevice: String
) throws {
    let feedbackProxy: WaylandProxy<ZwpLinuxDmabufFeedbackV1Client>
    do {
        feedbackProxy = try dmabuf.getDefaultFeedback()
    } catch {
        throw DisplayHostError.wayland(
            "could not request compositor dma-buf feedback")
    }
    defer { try? feedbackProxy.destroy() }
    let collector = DisplayDmabufFeedbackCollector()
    try feedbackProxy.installListener(collector)
    guard connection.bootstrapRoundtrip() >= 0 else {
        throw DisplayHostError.wayland(
            "dma-buf feedback roundtrip failed")
    }
    if let failure = collector.failure {
        throw DisplayHostError.wayland(
            "invalid compositor dma-buf feedback: \(failure)")
    }
    guard let feedback = collector.feedback else {
        throw DisplayHostError.wayland(
            "compositor dma-buf feedback was incomplete")
    }
    let candidates = try DrmDeviceDiscovery.enumerate()
    guard let candidate = candidates.first(where: {
        $0.renderNode == renderDevice
    }) else {
        throw DisplayHostError.wayland(
            "selected render node \(renderDevice) is absent from DRM discovery")
    }
    let device = try AndroidGraphicsDevice(candidate: candidate)
    for format in AndroidGraphicBufferFormat.requiredRenderingFormats {
        let exactPairs = feedback.orderedFormats.filter {
            $0.format == format.drmFormat && device.supports($0)
        }
        guard exactPairs.contains(where: {
            device.formatModifierProperties($0)?.planeCount
                == UInt32(format.planes.count)
        }) else {
            let drm = String(format: "0x%08x", format.drmFormat)
            throw DisplayHostError.wayland(
                "required \(format.name) contract unavailable: "
                    + "allocator/Vulkan/compositor share no single-plane "
                    + "\(drm) modifier on \(renderDevice)")
        }
    }
}

@safe private final class DisplayReadOnlyMapping {
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

@MainActor
private final class DisplayDmabufFeedbackCollector:
    ZwpLinuxDmabufFeedbackV1Events
{
    private var table: [DrmFormatModifier] = []
    private var mainDevice: GraphicsDeviceID?
    private var targetDevice: GraphicsDeviceID?
    private var indices: [UInt16] = []
    private var scanout = false
    private var tranches: [WaylandDmabufTranche] = []
    private(set) var feedback: WaylandDmabufFeedback?
    private(set) var failure: Error?

    func done(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>
    ) {
        guard let mainDevice, !tranches.isEmpty else {
            failure = DisplayHostError.wayland(
                "feedback omitted its device or tranches")
            return
        }
        feedback = WaylandDmabufFeedback(
            mainDevice: mainDevice, tranches: tranches)
    }

    func formatTable(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        fd: consuming WaylandClientOwnedFileDescriptor,
        size: UInt32
    ) {
        let descriptor = fd.take()
        defer { _ = close(descriptor) }
        guard size > 0, size % 16 == 0,
              let mapping = DisplayReadOnlyMapping(
                fileDescriptor: descriptor, byteCount: Int(size))
        else {
            failure = DisplayHostError.wayland(
                "invalid dma-buf format table")
            return
        }
        let data = mapping.copiedData()
        table = unsafe data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 16).map { offset in
                DrmFormatModifier(
                    format: unsafe bytes.loadUnaligned(
                        fromByteOffset: offset, as: UInt32.self),
                    modifier: unsafe bytes.loadUnaligned(
                        fromByteOffset: offset + 8, as: UInt64.self))
            }
        }
    }

    func mainDevice(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        device: WaylandClientArrayView
    ) {
        consumeDevice(device) { mainDevice = $0 }
    }

    func trancheTargetDevice(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        device: WaylandClientArrayView
    ) {
        consumeDevice(device) { targetDevice = $0 }
    }

    func trancheFormats(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        indices: WaylandClientArrayView
    ) {
        guard let values = indices.copiedElements(of: UInt16.self) else {
            failure = DisplayHostError.wayland(
                "invalid dma-buf tranche indices")
            return
        }
        self.indices = values
    }

    func trancheFlags(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        flags: ZwpLinuxDmabufFeedbackV1TrancheFlags
    ) {
        scanout = flags.rawValue & 1 != 0
    }

    func trancheDone(
        _ proxy: WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>
    ) {
        guard let targetDevice, !indices.isEmpty,
              indices.allSatisfy({ Int($0) < table.count })
        else {
            failure = DisplayHostError.wayland(
                "incomplete dma-buf tranche")
            return
        }
        tranches.append(WaylandDmabufTranche(
            targetDevice: targetDevice,
            scanout: scanout,
            formats: indices.map { table[Int($0)] }))
        self.targetDevice = nil
        indices = []
        scanout = false
    }

    private func consumeDevice(
        _ array: WaylandClientArrayView,
        _ consume: (GraphicsDeviceID) -> Void
    ) {
        var raw = nucleus_android_device_id()
        let result = unsafe array.withUnsafeBytes { bytes in
            unsafe nucleus_android_drm_device_id_from_native(
                bytes.baseAddress, bytes.count, &raw)
        }
        guard result == 0 else {
            failure = DisplayHostError.wayland(
                "invalid dma-buf device identity")
            return
        }
        consume(GraphicsDeviceID(major: raw.major, minor: raw.minor))
    }
}
