import Foundation

public enum AndroidGraphicsProtocol {
    public static let version: UInt16 = 2
    public static let maximumPacketBytes = 1 << 20
    public static let maximumFileDescriptors = 64
    public static let maximumDimension: UInt32 = 16_384
    public static let requiredBufferCount: UInt8 = 3
}

public struct GraphicsDeviceID: Codable, Hashable, Sendable {
    public var major: UInt32
    public var minor: UInt32

    public init(major: UInt32, minor: UInt32) {
        self.major = major
        self.minor = minor
    }
}

public struct PciDeviceID: Codable, Hashable, Sendable {
    public var domain: UInt16
    public var bus: UInt8
    public var device: UInt8
    public var function: UInt8
    public var vendor: UInt16
    public var product: UInt16

    public init(
        domain: UInt16,
        bus: UInt8,
        device: UInt8,
        function: UInt8,
        vendor: UInt16,
        product: UInt16
    ) {
        self.domain = domain
        self.bus = bus
        self.device = device
        self.function = function
        self.vendor = vendor
        self.product = product
    }

    public var address: String {
        String(format: "%04x:%02x:%02x.%x", domain, bus, device, function)
    }
}

public struct DrmFormatModifier: Codable, Hashable, Sendable {
    public var format: UInt32
    public var modifier: UInt64

    public init(format: UInt32, modifier: UInt64) {
        self.format = format
        self.modifier = modifier
    }
}

public struct WaylandDmabufTranche: Codable, Equatable, Sendable {
    public var targetDevice: GraphicsDeviceID
    public var scanout: Bool
    public var formats: [DrmFormatModifier]

    public init(
        targetDevice: GraphicsDeviceID,
        scanout: Bool,
        formats: [DrmFormatModifier]
    ) {
        self.targetDevice = targetDevice
        self.scanout = scanout
        self.formats = formats
    }
}

public struct WaylandDmabufFeedback: Codable, Equatable, Sendable {
    public var mainDevice: GraphicsDeviceID
    public var tranches: [WaylandDmabufTranche]

    public init(mainDevice: GraphicsDeviceID, tranches: [WaylandDmabufTranche]) {
        self.mainDevice = mainDevice
        self.tranches = tranches
    }

    public var orderedFormats: [DrmFormatModifier] {
        var seen = Set<DrmFormatModifier>()
        return tranches.flatMap(\.formats).filter { seen.insert($0).inserted }
    }
}

public struct BufferAllocationRequest: Codable, Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var bufferCount: UInt8
    public var feedback: WaylandDmabufFeedback

    public init(
        width: UInt32,
        height: UInt32,
        bufferCount: UInt8 = AndroidGraphicsProtocol.requiredBufferCount,
        feedback: WaylandDmabufFeedback
    ) {
        self.width = width
        self.height = height
        self.bufferCount = bufferCount
        self.feedback = feedback
    }
}

public enum GraphicsFileDescriptorRole: String, Codable, Equatable, Sendable {
    case dmaBufPlane
    case acquireTimeline
    case releaseTimeline
}

public struct GraphicsFileDescriptorSlot: Codable, Equatable, Sendable {
    public var index: UInt8
    public var role: GraphicsFileDescriptorRole
    public var bufferID: UInt64?
    public var planeIndex: UInt8?

    public init(
        index: UInt8,
        role: GraphicsFileDescriptorRole,
        bufferID: UInt64? = nil,
        planeIndex: UInt8? = nil
    ) {
        self.index = index
        self.role = role
        self.bufferID = bufferID
        self.planeIndex = planeIndex
    }
}

public struct DmabufPlane: Codable, Equatable, Sendable {
    public var fdIndex: UInt8
    public var offset: UInt32
    public var stride: UInt32

    public init(fdIndex: UInt8, offset: UInt32, stride: UInt32) {
        self.fdIndex = fdIndex
        self.offset = offset
        self.stride = stride
    }
}

public struct BrokerBuffer: Codable, Equatable, Sendable {
    public var id: UInt64
    public var width: UInt32
    public var height: UInt32
    public var format: UInt32
    public var modifier: UInt64
    public var planes: [DmabufPlane]
    public var releaseTimelineFDIndex: UInt8

    public init(
        id: UInt64,
        width: UInt32,
        height: UInt32,
        format: UInt32,
        modifier: UInt64,
        planes: [DmabufPlane],
        releaseTimelineFDIndex: UInt8
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.format = format
        self.modifier = modifier
        self.planes = planes
        self.releaseTimelineFDIndex = releaseTimelineFDIndex
    }
}

public struct TimelinePoint: Codable, Equatable, Sendable {
    public var timelineFDIndex: UInt8
    public var point: UInt64

    public init(timelineFDIndex: UInt8, point: UInt64) {
        self.timelineFDIndex = timelineFDIndex
        self.point = point
    }
}

public struct BufferAllocationReply: Codable, Equatable, Sendable {
    public var device: BrokerDeviceDiagnostic
    public var buffers: [BrokerBuffer]
    public var acquireTimelineFDIndex: UInt8

    public init(
        device: BrokerDeviceDiagnostic,
        buffers: [BrokerBuffer],
        acquireTimelineFDIndex: UInt8
    ) {
        self.device = device
        self.buffers = buffers
        self.acquireTimelineFDIndex = acquireTimelineFDIndex
    }
}

public struct RenderRequest: Codable, Equatable, Sendable {
    public var bufferID: UInt64
    public var frameNumber: UInt64
    public var releasePoint: UInt64?

    public init(bufferID: UInt64, frameNumber: UInt64, releasePoint: UInt64? = nil) {
        self.bufferID = bufferID
        self.frameNumber = frameNumber
        self.releasePoint = releasePoint
    }
}

public struct RenderReply: Codable, Equatable, Sendable {
    public var bufferID: UInt64
    public var frameNumber: UInt64
    public var acquirePoint: UInt64
    public var releasePoint: UInt64

    public init(
        bufferID: UInt64,
        frameNumber: UInt64,
        acquirePoint: UInt64,
        releasePoint: UInt64
    ) {
        self.bufferID = bufferID
        self.frameNumber = frameNumber
        self.acquirePoint = acquirePoint
        self.releasePoint = releasePoint
    }
}

public struct BrokerDeviceDiagnostic: Codable, Equatable, Sendable {
    public var renderNode: String
    public var primaryNode: String?
    public var renderDevice: GraphicsDeviceID
    public var primaryDevice: GraphicsDeviceID?
    public var pci: PciDeviceID
    public var vulkanDeviceName: String
    public var vulkanDriverName: String
    public var vulkanDriverInfo: String
    public var vulkanDeviceUUID: String
    public var vulkanAPIVersion: UInt32
    public var hardwareDriver: Bool
    public var gbmBackend: String

    public init(
        renderNode: String,
        primaryNode: String?,
        renderDevice: GraphicsDeviceID,
        primaryDevice: GraphicsDeviceID?,
        pci: PciDeviceID,
        vulkanDeviceName: String,
        vulkanDriverName: String,
        vulkanDriverInfo: String,
        vulkanDeviceUUID: String,
        vulkanAPIVersion: UInt32,
        hardwareDriver: Bool,
        gbmBackend: String
    ) {
        self.renderNode = renderNode
        self.primaryNode = primaryNode
        self.renderDevice = renderDevice
        self.primaryDevice = primaryDevice
        self.pci = pci
        self.vulkanDeviceName = vulkanDeviceName
        self.vulkanDriverName = vulkanDriverName
        self.vulkanDriverInfo = vulkanDriverInfo
        self.vulkanDeviceUUID = vulkanDeviceUUID
        self.vulkanAPIVersion = vulkanAPIVersion
        self.hardwareDriver = hardwareDriver
        self.gbmBackend = gbmBackend
    }
}

public struct GraphicsFailure: Codable, Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BrokerMessageKind: String, Codable, Sendable {
    case hello
    case helloReply
    case diagnose
    case diagnostic
    case allocate
    case allocationReply
    case render
    case renderReply
    case failure
}

public struct BrokerEnvelope: Codable, Equatable, Sendable {
    public var protocolVersion: UInt16
    public var messageID: UInt64
    public var kind: BrokerMessageKind
    public var allocationRequest: BufferAllocationRequest?
    public var allocationReply: BufferAllocationReply?
    public var renderRequest: RenderRequest?
    public var renderReply: RenderReply?
    public var diagnostic: BrokerDeviceDiagnostic?
    public var failure: GraphicsFailure?
    public var descriptorSlots: [GraphicsFileDescriptorSlot]

    public init(
        protocolVersion: UInt16 = AndroidGraphicsProtocol.version,
        messageID: UInt64,
        kind: BrokerMessageKind,
        allocationRequest: BufferAllocationRequest? = nil,
        allocationReply: BufferAllocationReply? = nil,
        renderRequest: RenderRequest? = nil,
        renderReply: RenderReply? = nil,
        diagnostic: BrokerDeviceDiagnostic? = nil,
        failure: GraphicsFailure? = nil,
        descriptorSlots: [GraphicsFileDescriptorSlot] = []
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.kind = kind
        self.allocationRequest = allocationRequest
        self.allocationReply = allocationReply
        self.renderRequest = renderRequest
        self.renderReply = renderReply
        self.diagnostic = diagnostic
        self.failure = failure
        self.descriptorSlots = descriptorSlots
    }
}

public enum GraphicsContractValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case invalidPayload(BrokerMessageKind)
    case invalidDimensions
    case invalidBufferCount(UInt8)
    case emptyFeedback
    case invalidDescriptorSlots
    case descriptorCountMismatch(expected: Int, actual: Int)
    case invalidAllocationReply
    case invalidRenderContract
}

extension BrokerEnvelope {
    public func validate(receivedFileDescriptorCount: Int) throws {
        guard protocolVersion == AndroidGraphicsProtocol.version else {
            throw GraphicsContractValidationError.unsupportedVersion(protocolVersion)
        }
        let payloadCount = [
            allocationRequest != nil,
            allocationReply != nil,
            renderRequest != nil,
            renderReply != nil,
            diagnostic != nil,
            failure != nil,
        ].filter { $0 }.count
        let expectedPayloadCount: Int
        switch kind {
        case .hello, .helloReply, .diagnose:
            expectedPayloadCount = 0
        case .allocate:
            expectedPayloadCount = allocationRequest == nil ? -1 : 1
        case .allocationReply:
            expectedPayloadCount = allocationReply == nil ? -1 : 1
        case .render:
            expectedPayloadCount = renderRequest == nil ? -1 : 1
        case .renderReply:
            expectedPayloadCount = renderReply == nil ? -1 : 1
        case .diagnostic:
            expectedPayloadCount = diagnostic == nil ? -1 : 1
        case .failure:
            expectedPayloadCount = failure == nil ? -1 : 1
        }
        guard payloadCount == expectedPayloadCount else {
            throw GraphicsContractValidationError.invalidPayload(kind)
        }
        if let request = allocationRequest {
            guard request.width > 0, request.height > 0,
                  request.width <= AndroidGraphicsProtocol.maximumDimension,
                  request.height <= AndroidGraphicsProtocol.maximumDimension
            else { throw GraphicsContractValidationError.invalidDimensions }
            guard request.bufferCount == AndroidGraphicsProtocol.requiredBufferCount else {
                throw GraphicsContractValidationError.invalidBufferCount(request.bufferCount)
            }
            guard !request.feedback.tranches.isEmpty,
                  !request.feedback.orderedFormats.isEmpty
            else { throw GraphicsContractValidationError.emptyFeedback }
        }
        let indices = descriptorSlots.map { Int($0.index) }
        guard Set(indices).count == indices.count,
              indices.sorted() == Array(0..<indices.count),
              indices.count <= AndroidGraphicsProtocol.maximumFileDescriptors,
              descriptorSlots.allSatisfy({ slot in
                  switch slot.role {
                  case .dmaBufPlane:
                      return slot.bufferID != nil && slot.planeIndex != nil
                  case .acquireTimeline:
                      return slot.bufferID == nil && slot.planeIndex == nil
                  case .releaseTimeline:
                      return slot.bufferID != nil && slot.planeIndex == nil
                  }
              })
        else { throw GraphicsContractValidationError.invalidDescriptorSlots }
        guard receivedFileDescriptorCount == descriptorSlots.count else {
            throw GraphicsContractValidationError.descriptorCountMismatch(
                expected: descriptorSlots.count,
                actual: receivedFileDescriptorCount)
        }
        if let reply = allocationReply {
            let bufferIDs = reply.buffers.map(\.id)
            var usedIndices = Set<Int>()
            guard reply.buffers.count == Int(AndroidGraphicsProtocol.requiredBufferCount),
                  reply.device.vulkanDeviceUUID.count == 32,
                  reply.device.vulkanDeviceUUID.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                  }),
                  reply.device.vulkanDeviceUUID != String(repeating: "0", count: 32),
                  Set(bufferIDs).count == bufferIDs.count,
                  bufferIDs.allSatisfy({ $0 > 0 }),
                  descriptorSlots.indices.contains(Int(reply.acquireTimelineFDIndex)),
                  descriptorSlots[Int(reply.acquireTimelineFDIndex)].role == .acquireTimeline
            else { throw GraphicsContractValidationError.invalidAllocationReply }
            usedIndices.insert(Int(reply.acquireTimelineFDIndex))
            for buffer in reply.buffers {
                guard buffer.width > 0,
                      buffer.height > 0,
                      buffer.width <= AndroidGraphicsProtocol.maximumDimension,
                      buffer.height <= AndroidGraphicsProtocol.maximumDimension,
                      !buffer.planes.isEmpty,
                      buffer.planes.count <= 4,
                      descriptorSlots.indices.contains(Int(buffer.releaseTimelineFDIndex)),
                      descriptorSlots[Int(buffer.releaseTimelineFDIndex)].role == .releaseTimeline,
                      descriptorSlots[Int(buffer.releaseTimelineFDIndex)].bufferID == buffer.id
                else { throw GraphicsContractValidationError.invalidAllocationReply }
                usedIndices.insert(Int(buffer.releaseTimelineFDIndex))
                for (planeIndex, plane) in buffer.planes.enumerated() {
                    guard plane.stride > 0,
                          descriptorSlots.indices.contains(Int(plane.fdIndex)),
                          descriptorSlots[Int(plane.fdIndex)].role == .dmaBufPlane,
                          descriptorSlots[Int(plane.fdIndex)].bufferID == buffer.id,
                          descriptorSlots[Int(plane.fdIndex)].planeIndex == UInt8(planeIndex)
                    else { throw GraphicsContractValidationError.invalidAllocationReply }
                    usedIndices.insert(Int(plane.fdIndex))
                }
            }
            guard usedIndices.count == descriptorSlots.count else {
                throw GraphicsContractValidationError.invalidAllocationReply
            }
        }
        if let renderRequest {
            guard renderRequest.bufferID > 0, renderRequest.frameNumber > 0 else {
                throw GraphicsContractValidationError.invalidRenderContract
            }
        }
        if let renderReply {
            guard renderReply.bufferID > 0,
                  renderReply.frameNumber > 0,
                  renderReply.acquirePoint > 0,
                  renderReply.releasePoint > 0
            else { throw GraphicsContractValidationError.invalidRenderContract }
        }
    }
}
