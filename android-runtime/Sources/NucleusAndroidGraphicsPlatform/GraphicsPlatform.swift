import Glibc
import NucleusAndroidDrmC
import NucleusAndroidGraphicsContract

public struct DrmDeviceCandidate: Equatable, Sendable {
    public var renderNode: String
    public var primaryNode: String?
    public var renderDevice: GraphicsDeviceID
    public var primaryDevice: GraphicsDeviceID?
    public var pci: PciDeviceID

    public init(
        renderNode: String,
        primaryNode: String?,
        renderDevice: GraphicsDeviceID,
        primaryDevice: GraphicsDeviceID?,
        pci: PciDeviceID
    ) {
        self.renderNode = renderNode
        self.primaryNode = primaryNode
        self.renderDevice = renderDevice
        self.primaryDevice = primaryDevice
        self.pci = pci
    }

    public func matches(_ device: GraphicsDeviceID) -> Bool {
        renderDevice == device || primaryDevice == device
    }
}

public enum GraphicsPlatformError: Error, Equatable, Sendable {
    case drmEnumerationFailed(errno: Int32)
    case compositorDeviceNotFound(GraphicsDeviceID)
    case ambiguousCompositorDevice(GraphicsDeviceID)
    case gpuInitializationFailed(String)
    case noCompatibleFormatModifier
    case allocationFailed(String)
    case timelineCreationFailed(errno: Int32)
    case timelineExportFailed(errno: Int32)
    case renderFailed(String)
}

public enum DrmDeviceDiscovery {
    public static func enumerate() throws -> [DrmDeviceCandidate] {
        let count = nucleus_android_drm_enumerate(nil, 0)
        guard count >= 0 else {
            throw GraphicsPlatformError.drmEnumerationFailed(errno: errno)
        }
        if count == 0 { return [] }
        var raw = [nucleus_android_drm_candidate](
            repeating: nucleus_android_drm_candidate(),
            count: Int(count))
        let filled = raw.withUnsafeMutableBufferPointer { buffer in
            nucleus_android_drm_enumerate(buffer.baseAddress, buffer.count)
        }
        guard filled >= 0 else {
            throw GraphicsPlatformError.drmEnumerationFailed(errno: errno)
        }
        return raw.prefix(min(Int(filled), raw.count)).map { candidate in
            let renderNode = string(from: candidate.render_path)
            let primary = string(from: candidate.primary_path)
            return DrmDeviceCandidate(
                renderNode: renderNode,
                primaryNode: primary.isEmpty ? nil : primary,
                renderDevice: GraphicsDeviceID(
                    major: candidate.render_device.major,
                    minor: candidate.render_device.minor),
                primaryDevice: primary.isEmpty
                    ? nil
                    : GraphicsDeviceID(
                        major: candidate.primary_device.major,
                        minor: candidate.primary_device.minor),
                pci: PciDeviceID(
                    domain: candidate.pci_domain,
                    bus: candidate.pci_bus,
                    device: candidate.pci_device,
                    function: candidate.pci_function,
                    vendor: candidate.vendor_id,
                    product: candidate.product_id))
        }
    }

    public static func select(
        compositorDevice: GraphicsDeviceID,
        from candidates: [DrmDeviceCandidate]
    ) throws -> DrmDeviceCandidate {
        let matches = candidates.filter { $0.matches(compositorDevice) }
        switch matches.count {
        case 0:
            throw GraphicsPlatformError.compositorDeviceNotFound(compositorDevice)
        case 1:
            return matches[0]
        default:
            throw GraphicsPlatformError.ambiguousCompositorDevice(compositorDevice)
        }
    }
}

private final class GraphicsDeviceResource {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { nucleus_android_gpu_destroy(handle) }
}

public final class AndroidGraphicsDevice: @unchecked Sendable {
    public let candidate: DrmDeviceCandidate
    public let diagnostic: BrokerDeviceDiagnostic
    private let resource: GraphicsDeviceResource

    public convenience init(compositorDevice: GraphicsDeviceID) throws {
        let candidates = try DrmDeviceDiscovery.enumerate()
        let selected = try DrmDeviceDiscovery.select(
            compositorDevice: compositorDevice,
            from: candidates)
        try self.init(candidate: selected)
    }

    public init(candidate: DrmDeviceCandidate) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let handle = candidate.renderNode.withCString { path in
            nucleus_android_gpu_create(path, &error, error.count)
        }
        guard let handle else {
            throw GraphicsPlatformError.gpuInitializationFailed(string(from: error))
        }
        var raw = nucleus_android_gpu_diagnostic()
        guard nucleus_android_gpu_get_diagnostic(handle, &raw) == 0 else {
            nucleus_android_gpu_destroy(handle)
            throw GraphicsPlatformError.gpuInitializationFailed("GPU diagnostic unavailable")
        }
        let resource = GraphicsDeviceResource(handle: handle)
        self.candidate = candidate
        self.resource = resource
        diagnostic = BrokerDeviceDiagnostic(
            renderNode: candidate.renderNode,
            primaryNode: candidate.primaryNode,
            renderDevice: candidate.renderDevice,
            primaryDevice: candidate.primaryDevice,
            pci: candidate.pci,
            vulkanDeviceName: string(from: raw.device_name),
            vulkanDriverName: string(from: raw.driver_name),
            vulkanDriverInfo: string(from: raw.driver_info),
            vulkanDeviceUUID: string(from: raw.device_uuid),
            vulkanAPIVersion: raw.api_version,
            hardwareDriver: raw.hardware_driver != 0,
            gbmBackend: string(from: raw.gbm_backend))
    }

    public func supports(_ pair: DrmFormatModifier) -> Bool {
        nucleus_android_gpu_supports_format_modifier(
            resource.handle,
            pair.format,
            pair.modifier) == 1
    }

    public func formatModifierProperties(
        _ pair: DrmFormatModifier
    ) -> (planeCount: UInt32, features: UInt64)? {
        var planeCount: UInt32 = 0
        var features: UInt64 = 0
        guard nucleus_android_gpu_format_modifier_properties(
            resource.handle,
            pair.format,
            pair.modifier,
            &planeCount,
            &features) == 1
        else { return nil }
        return (planeCount, features)
    }

    public func formatModifiers(
        format: UInt32
    ) -> [(pair: DrmFormatModifier, planeCount: UInt32, features: UInt64)] {
        let count = nucleus_android_gpu_list_format_modifiers(
            resource.handle,
            format,
            nil,
            0)
        guard count > 0 else { return [] }
        var raw = [nucleus_android_format_modifier_properties](
            repeating: nucleus_android_format_modifier_properties(),
            count: Int(count))
        let filled = raw.withUnsafeMutableBufferPointer { buffer in
            nucleus_android_gpu_list_format_modifiers(
                resource.handle,
                format,
                buffer.baseAddress,
                buffer.count)
        }
        guard filled >= 0 else { return [] }
        return raw.prefix(min(Int(filled), raw.count)).map { properties in
            (
                pair: DrmFormatModifier(format: format, modifier: properties.modifier),
                planeCount: properties.plane_count,
                features: properties.features)
        }
    }

    public func gbmPreferredFormatModifier(format: UInt32) -> DrmFormatModifier? {
        var modifier: UInt64 = 0
        guard nucleus_android_gpu_preferred_modifier(
            resource.handle,
            format,
            &modifier) == 0
        else { return nil }
        return DrmFormatModifier(format: format, modifier: modifier)
    }

    public func preferredFormatModifier(format: UInt32) -> DrmFormatModifier? {
        guard let pair = gbmPreferredFormatModifier(format: format), supports(pair) else {
            return nil
        }
        return pair
    }

    public func allocate(_ request: BufferAllocationRequest) throws -> AndroidBufferRing {
        try BrokerEnvelope(
            messageID: 0,
            kind: .allocate,
            allocationRequest: request)
            .validate(receivedFileDescriptorCount: 0)

        var foundSupportedPair = false
        var lastAllocationFailure: String?
        for pair in request.feedback.orderedFormats where supports(pair) {
            foundSupportedPair = true
            let scanout = request.feedback.tranches.contains { tranche in
                tranche.scanout && tranche.formats.contains(pair)
            }
            var buffers: [AndroidGraphicsBuffer] = []
            for index in 0..<Int(request.bufferCount) {
                var error = [CChar](repeating: 0, count: 1024)
                let handle = nucleus_android_gpu_buffer_create(
                    resource.handle,
                    request.width,
                    request.height,
                    pair.format,
                    pair.modifier,
                    scanout ? 1 : 0,
                    &error,
                    error.count)
                guard let handle else {
                    lastAllocationFailure = string(from: error)
                    buffers.removeAll()
                    break
                }
                buffers.append(AndroidGraphicsBuffer(
                    id: UInt64(index + 1),
                    width: request.width,
                    height: request.height,
                    formatModifier: pair,
                    handle: handle,
                    resource: resource))
            }
            guard buffers.count == Int(request.bufferCount) else {
                continue
            }
            guard let acquire = AndroidSyncobjTimeline(resource: resource) else {
                throw GraphicsPlatformError.timelineCreationFailed(errno: errno)
            }
            var releases: [UInt64: AndroidSyncobjTimeline] = [:]
            for buffer in buffers {
                guard let release = AndroidSyncobjTimeline(resource: resource) else {
                    throw GraphicsPlatformError.timelineCreationFailed(errno: errno)
                }
                releases[buffer.id] = release
            }
            return AndroidBufferRing(
                buffers: buffers,
                acquireTimeline: acquire,
                releaseTimelines: releases,
                diagnostic: diagnostic)
        }
        if foundSupportedPair, let lastAllocationFailure {
            throw GraphicsPlatformError.allocationFailed(lastAllocationFailure)
        }
        throw GraphicsPlatformError.noCompatibleFormatModifier
    }
}

public struct ExportedDmabufPlane: ~Copyable {
    public let offset: UInt32
    public let stride: UInt32
    private var fileDescriptor: Int32

    init(offset: UInt32, stride: UInt32, fileDescriptor: Int32) {
        self.offset = offset
        self.stride = stride
        self.fileDescriptor = fileDescriptor
    }

    public consuming func takeFileDescriptor() -> Int32 {
        let taken = fileDescriptor
        fileDescriptor = -1
        discard self
        return taken
    }

    deinit {
        if fileDescriptor >= 0 { _ = close(fileDescriptor) }
    }
}

public final class AndroidGraphicsBuffer: @unchecked Sendable {
    public let id: UInt64
    public let width: UInt32
    public let height: UInt32
    public let formatModifier: DrmFormatModifier
    private let handle: OpaquePointer
    private let resource: GraphicsDeviceResource

    fileprivate init(
        id: UInt64,
        width: UInt32,
        height: UInt32,
        formatModifier: DrmFormatModifier,
        handle: OpaquePointer,
        resource: GraphicsDeviceResource
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.formatModifier = formatModifier
        self.handle = handle
        self.resource = resource
    }

    public var planeCount: UInt32 {
        nucleus_android_gpu_buffer_plane_count(handle)
    }

    public func exportPlane(at index: UInt32) throws -> ExportedDmabufPlane {
        var layout = nucleus_android_dmabuf_plane()
        let descriptor = nucleus_android_gpu_buffer_export_plane(handle, index, &layout)
        guard descriptor >= 0 else {
            throw GraphicsPlatformError.allocationFailed("dma-buf plane export failed: errno \(errno)")
        }
        return ExportedDmabufPlane(
            offset: layout.offset,
            stride: layout.stride,
            fileDescriptor: descriptor)
    }

    public func render(
        frameNumber: UInt64,
        acquireTimeline: AndroidSyncobjTimeline,
        acquirePoint: UInt64,
        releaseTimeline: AndroidSyncobjTimeline? = nil,
        releasePoint: UInt64 = 0
    ) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard nucleus_android_gpu_buffer_render(
            handle,
            frameNumber,
            acquireTimeline.handle,
            acquirePoint,
            releaseTimeline?.handle,
            releasePoint,
            &error,
            error.count) == 0
        else { throw GraphicsPlatformError.renderFailed(string(from: error)) }
    }

    deinit { nucleus_android_gpu_buffer_destroy(handle) }
}

public final class AndroidSyncobjTimeline: @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    private let resource: GraphicsDeviceResource

    fileprivate init?(resource: GraphicsDeviceResource) {
        guard let handle = nucleus_android_syncobj_timeline_create(resource.handle) else {
            return nil
        }
        self.handle = handle
        self.resource = resource
    }

    public func exportFileDescriptor() throws -> Int32 {
        let descriptor = nucleus_android_syncobj_timeline_export_fd(handle)
        guard descriptor >= 0 else {
            throw GraphicsPlatformError.timelineExportFailed(errno: errno)
        }
        return descriptor
    }

    public func signal(point: UInt64) -> Bool {
        nucleus_android_syncobj_timeline_signal(handle, point) == 0
    }

    public func isSignaled(point: UInt64) -> Bool? {
        switch nucleus_android_syncobj_timeline_is_signaled(handle, point) {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    deinit { nucleus_android_syncobj_timeline_destroy(handle) }
}

public final class AndroidBufferRing: @unchecked Sendable {
    public let buffers: [AndroidGraphicsBuffer]
    public let acquireTimeline: AndroidSyncobjTimeline
    public let releaseTimelines: [UInt64: AndroidSyncobjTimeline]
    public let diagnostic: BrokerDeviceDiagnostic

    fileprivate init(
        buffers: [AndroidGraphicsBuffer],
        acquireTimeline: AndroidSyncobjTimeline,
        releaseTimelines: [UInt64: AndroidSyncobjTimeline],
        diagnostic: BrokerDeviceDiagnostic
    ) {
        self.buffers = buffers
        self.acquireTimeline = acquireTimeline
        self.releaseTimelines = releaseTimelines
        self.diagnostic = diagnostic
    }

    public func releaseTimeline(for bufferID: UInt64) -> AndroidSyncobjTimeline? {
        releaseTimelines[bufferID]
    }
}

public enum DrmFormats {
    public static let xrgb8888 = nucleus_android_drm_format_xrgb8888()
    public static let argb8888 = nucleus_android_drm_format_argb8888()
    public static let xbgr8888 = nucleus_android_drm_format_xbgr8888()
    public static let abgr8888 = nucleus_android_drm_format_abgr8888()
    public static let linearModifier = nucleus_android_drm_modifier_linear()
}

private func string<T>(from tuple: T) -> String {
    withUnsafeBytes(of: tuple) { bytes in
        guard let base = bytes.baseAddress else { return "" }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}

private func string(from bytes: [CChar]) -> String {
    let prefix = bytes.prefix { $0 != 0 }
    return String(decoding: prefix.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
