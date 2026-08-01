import Foundation

package struct AndroidGraphicBufferFormat: Equatable, Sendable {
  package struct Plane: Equatable, Sendable {
    package let horizontalSubsampling: UInt8
    package let verticalSubsampling: UInt8
    package let bytesPerElement: UInt8

    package init(
      horizontalSubsampling: UInt8 = 1,
      verticalSubsampling: UInt8 = 1,
      bytesPerElement: UInt8
    ) {
      self.horizontalSubsampling = horizontalSubsampling
      self.verticalSubsampling = verticalSubsampling
      self.bytesPerElement = bytesPerElement
    }
  }

  package let name: String
  package let androidFormat: UInt32
  package let bytesPerPixel: UInt8
  package let componentBits: [UInt8]
  package let drmFormat: UInt32
  package let vulkanFormat: UInt32
  package let planes: [Plane]

  package init(
    name: String,
    androidFormat: UInt32,
    bytesPerPixel: UInt8,
    componentBits: [UInt8],
    drmFormat: UInt32,
    vulkanFormat: UInt32,
    planes: [Plane]
  ) {
    self.name = name
    self.androidFormat = androidFormat
    self.bytesPerPixel = bytesPerPixel
    self.componentBits = componentBits
    self.drmFormat = drmFormat
    self.vulkanFormat = vulkanFormat
    self.planes = planes
  }

  package static let requiredRenderingFormats: [Self] = [
    Self(
      name: "RGBX_8888",
      androidFormat: 2,
      bytesPerPixel: 4,
      componentBits: [8, 8, 8, 0],
      drmFormat: drmFourCC(88, 66, 50, 52),
      vulkanFormat: 37,
      planes: [Plane(bytesPerElement: 4)]),
    Self(
      name: "RGBA_8888",
      androidFormat: 1,
      bytesPerPixel: 4,
      componentBits: [8, 8, 8, 8],
      drmFormat: drmFourCC(65, 66, 50, 52),
      vulkanFormat: 37,
      planes: [Plane(bytesPerElement: 4)]),
    Self(
      name: "RGBA_FP16",
      androidFormat: 22,
      bytesPerPixel: 8,
      componentBits: [16, 16, 16, 16],
      drmFormat: drmFourCC(65, 66, 52, 72),
      vulkanFormat: 97,
      planes: [Plane(bytesPerElement: 8)]),
    Self(
      name: "RGBA_1010102",
      androidFormat: 43,
      bytesPerPixel: 4,
      componentBits: [10, 10, 10, 2],
      drmFormat: drmFourCC(65, 66, 51, 48),
      vulkanFormat: 64,
      planes: [Plane(bytesPerElement: 4)]),
  ]
}

private func drmFourCC(
  _ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32
) -> UInt32 {
  a | b << 8 | c << 16 | d << 24
}

package enum AndroidGraphicsProtocol {
  package static let maximumPacketBytes = 1 << 20
  package static let maximumFileDescriptors = 64
  package static let maximumDimension: UInt32 = 16_384
  package static let requiredBufferCount: UInt8 = 3
}

package struct GraphicsDeviceID: Codable, Hashable, Sendable {
  package var major: UInt32
  package var minor: UInt32

  package init(major: UInt32, minor: UInt32) {
    self.major = major
    self.minor = minor
  }
}

package struct PciDeviceID: Codable, Hashable, Sendable {
  package var domain: UInt16
  package var bus: UInt8
  package var device: UInt8
  package var function: UInt8
  package var vendor: UInt16
  package var product: UInt16

  package init(
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

  package var address: String {
    String(format: "%04x:%02x:%02x.%x", domain, bus, device, function)
  }
}

package struct DrmFormatModifier: Codable, Hashable, Sendable {
  package var format: UInt32
  package var modifier: UInt64

  package init(format: UInt32, modifier: UInt64) {
    self.format = format
    self.modifier = modifier
  }
}

package struct WaylandDmabufTranche: Codable, Equatable, Sendable {
  package var targetDevice: GraphicsDeviceID
  package var scanout: Bool
  package var formats: [DrmFormatModifier]

  package init(
    targetDevice: GraphicsDeviceID,
    scanout: Bool,
    formats: [DrmFormatModifier]
  ) {
    self.targetDevice = targetDevice
    self.scanout = scanout
    self.formats = formats
  }
}

package struct WaylandDmabufFeedback: Codable, Equatable, Sendable {
  package var mainDevice: GraphicsDeviceID
  package var tranches: [WaylandDmabufTranche]

  package init(mainDevice: GraphicsDeviceID, tranches: [WaylandDmabufTranche]) {
    self.mainDevice = mainDevice
    self.tranches = tranches
  }

  package var orderedFormats: [DrmFormatModifier] {
    var seen = Set<DrmFormatModifier>()
    return tranches.flatMap(\.formats).filter { seen.insert($0).inserted }
  }
}

package struct BufferAllocationRequest: Codable, Equatable, Sendable {
  package var width: UInt32
  package var height: UInt32
  package var bufferCount: UInt8
  package var feedback: WaylandDmabufFeedback

  package init(
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

package enum GraphicsFileDescriptorRole: String, Codable, Equatable, Sendable {
  case dmaBufPlane
  case acquireTimeline
  case releaseTimeline
}

package struct GraphicsFileDescriptorSlot: Codable, Equatable, Sendable {
  package var index: UInt8
  package var role: GraphicsFileDescriptorRole
  package var bufferID: UInt64?
  package var planeIndex: UInt8?

  package init(
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

package struct DmabufPlane: Codable, Equatable, Sendable {
  package var fdIndex: UInt8
  package var offset: UInt32
  package var stride: UInt32

  package init(fdIndex: UInt8, offset: UInt32, stride: UInt32) {
    self.fdIndex = fdIndex
    self.offset = offset
    self.stride = stride
  }
}

package struct BrokerBuffer: Codable, Equatable, Sendable {
  package var id: UInt64
  package var width: UInt32
  package var height: UInt32
  package var format: UInt32
  package var modifier: UInt64
  package var planes: [DmabufPlane]
  package var releaseTimelineFDIndex: UInt8

  package init(
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

package struct TimelinePoint: Codable, Equatable, Sendable {
  package var timelineFDIndex: UInt8
  package var point: UInt64

  package init(timelineFDIndex: UInt8, point: UInt64) {
    self.timelineFDIndex = timelineFDIndex
    self.point = point
  }
}

package struct BufferAllocationReply: Codable, Equatable, Sendable {
  package var device: BrokerDeviceDiagnostic
  package var buffers: [BrokerBuffer]
  package var acquireTimelineFDIndex: UInt8

  package init(
    device: BrokerDeviceDiagnostic,
    buffers: [BrokerBuffer],
    acquireTimelineFDIndex: UInt8
  ) {
    self.device = device
    self.buffers = buffers
    self.acquireTimelineFDIndex = acquireTimelineFDIndex
  }
}

package struct RenderRequest: Codable, Equatable, Sendable {
  package var bufferID: UInt64
  package var frameNumber: UInt64
  package var releasePoint: UInt64?

  package init(bufferID: UInt64, frameNumber: UInt64, releasePoint: UInt64? = nil) {
    self.bufferID = bufferID
    self.frameNumber = frameNumber
    self.releasePoint = releasePoint
  }
}

package struct RenderReply: Codable, Equatable, Sendable {
  package var bufferID: UInt64
  package var frameNumber: UInt64
  package var acquirePoint: UInt64
  package var releasePoint: UInt64

  package init(
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

package struct BrokerDeviceDiagnostic: Codable, Equatable, Sendable {
  package var renderNode: String
  package var primaryNode: String?
  package var renderDevice: GraphicsDeviceID
  package var primaryDevice: GraphicsDeviceID?
  package var pci: PciDeviceID
  package var vulkanDeviceName: String
  package var vulkanDriverName: String
  package var vulkanDriverInfo: String
  package var vulkanDeviceUUID: String
  package var vulkanAPIVersion: UInt32
  package var hardwareDriver: Bool
  package var gbmBackend: String

  package init(
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

package struct GraphicsFailure: Codable, Error, Equatable, Sendable {
  package var code: String
  package var message: String

  package init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

package enum BrokerMessageKind: String, Codable, Sendable {
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

package struct BrokerEnvelope: Codable, Equatable, Sendable {
  package var messageID: UInt64
  package var kind: BrokerMessageKind
  package var allocationRequest: BufferAllocationRequest?
  package var allocationReply: BufferAllocationReply?
  package var renderRequest: RenderRequest?
  package var renderReply: RenderReply?
  package var diagnostic: BrokerDeviceDiagnostic?
  package var failure: GraphicsFailure?
  package var descriptorSlots: [GraphicsFileDescriptorSlot]

  package init(
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

package enum GraphicsContractValidationError: Error, Equatable, Sendable {
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
  package func validate(receivedFileDescriptorCount: Int) throws {
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
