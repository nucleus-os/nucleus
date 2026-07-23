import Glibc
import Synchronization
import Testing
import Vulkan
import VulkanC
@testable import NucleusRenderer

private enum DmaBufImportFailure: Sendable {
    case none
    case createImage
    case memoryProperties
    case allocateMemory
    case bindMemory
}

private enum FakeDmaBufImporter {
    struct State: Sendable {
        var failure = DmaBufImportFailure.none
        var events: [String] = []
    }

    static let state = Mutex(State())
    static var image: OpaquePointer {
        OpaquePointer(bitPattern: 0x1111)!
    }
    static var memory: OpaquePointer {
        OpaquePointer(bitPattern: 0x2222)!
    }

    static func reset(failure: DmaBufImportFailure) {
        state.withLock {
            $0.failure = failure
            $0.events.removeAll(keepingCapacity: true)
        }
    }

    static var events: [String] {
        state.withLock(\.events)
    }

    static var operations: DmaBufImportOperations {
        DmaBufImportOperations(
            createImage: { _, _, _, output in
                let failure = FakeDmaBufImporter.state.withLock {
                    $0.events.append("create-image")
                    return $0.failure
                }
                guard failure != .createImage else {
                    return VK_ERROR_OUT_OF_DEVICE_MEMORY
                }
                output?.pointee = FakeDmaBufImporter.image
                return VK_SUCCESS
            },
            destroyImage: { _, _, _ in
                FakeDmaBufImporter.state.withLock {
                    $0.events.append("destroy-image")
                }
            },
            allocateMemory: { _, info, _, output in
                let failure = FakeDmaBufImporter.state.withLock {
                    $0.events.append("allocate-memory")
                    return $0.failure
                }
                guard failure != .allocateMemory else {
                    return VK_ERROR_OUT_OF_DEVICE_MEMORY
                }
                guard let importInfo = info?.pointee.pNext?
                    .assumingMemoryBound(to: VkImportMemoryFdInfoKHR.self)
                else { return VK_ERROR_INVALID_EXTERNAL_HANDLE }
                // A successful Vulkan fd import consumes ownership.
                _ = close(importInfo.pointee.fd)
                output?.pointee = FakeDmaBufImporter.memory
                return VK_SUCCESS
            },
            freeMemory: { _, _, _ in
                FakeDmaBufImporter.state.withLock {
                    $0.events.append("free-memory")
                }
            },
            bindImageMemory: { _, _, _, _ in
                let failure = FakeDmaBufImporter.state.withLock {
                    $0.events.append("bind-memory")
                    return $0.failure
                }
                return failure == .bindMemory
                    ? VK_ERROR_INVALID_EXTERNAL_HANDLE
                    : VK_SUCCESS
            },
            bindImageMemory2: { _, _, _ in
                VK_ERROR_FEATURE_NOT_PRESENT
            },
            getMemoryFdProperties: { _, _, _, properties in
                let failure = FakeDmaBufImporter.state.withLock {
                    $0.events.append("memory-properties")
                    return $0.failure
                }
                guard failure != .memoryProperties else {
                    return VK_ERROR_INVALID_EXTERNAL_HANDLE
                }
                properties?.pointee.memoryTypeBits = 1
                return VK_SUCCESS
            },
            getImageMemoryRequirements: { _, _, requirements in
                FakeDmaBufImporter.state.withLock {
                    $0.events.append("memory-requirements")
                }
                requirements?.pointee.size = 4_096
                requirements?.pointee.alignment = 4_096
                requirements?.pointee.memoryTypeBits = 1
            },
            getImageMemoryRequirements2: { _, _, _ in })
    }
}

@Suite(.serialized) struct NucleusVulkanDmaBufTests {
    private func convert(
        _ pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        format: UInt32,
        stride: UInt32
    ) -> [UInt8]? {
        convertClientShmToRGBA(
            pixels: pixels.span,
            width: width,
            height: height,
            drmFormat: format,
            stride: stride)
    }

    @Test func convertsPaddedARGBRowsToTightRGBA() {
        let pixels: [UInt8] = [
            0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0xee, 0xee, 0xee, 0xee,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xee, 0xee, 0xee, 0xee,
        ]
        #expect(
            convert(
                pixels,
                width: 2,
                height: 2,
                format: DrmFourcc.argb8888,
                stride: 12
            ) == [
                0x30, 0x20, 0x10, 0x40, 0x70, 0x60, 0x50, 0x80,
                0x03, 0x02, 0x01, 0x04, 0x07, 0x06, 0x05, 0x08,
            ])
    }

    @Test func convertsTightXRGBToOpaqueRGBA() {
        #expect(
            convert(
                [0x10, 0x20, 0x30, 0x00],
                width: 1,
                height: 1,
                format: DrmFourcc.xrgb8888,
                stride: 4
            ) == [0x30, 0x20, 0x10, 0xff])
    }

    @Test func rejectsInvalidLayoutsBeforeReading() {
        #expect(
            convert(
                [],
                width: 0,
                height: 1,
                format: DrmFourcc.argb8888,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [0, 0, 0, 0],
                width: 2,
                height: 1,
                format: DrmFourcc.argb8888,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [0, 0, 0],
                width: 1,
                height: 1,
                format: DrmFourcc.argb8888,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [0, 0, 0, 0],
                width: 1,
                height: 1,
                format: 0xffff_ffff,
                stride: 4
            ) == nil)
        #expect(
            convert(
                [],
                width: .max,
                height: .max,
                format: DrmFourcc.argb8888,
                stride: .max
            ) == nil)
    }

    @Test func returnedPixelsDoNotBorrowSourceStorage() {
        var source = [UInt8]([0x10, 0x20, 0x30, 0x40])
        let converted = convertClientShmToRGBA(
            pixels: source.span,
            width: 1,
            height: 1,
            drmFormat: DrmFourcc.argb8888,
            stride: 4)
        source = [0xff, 0xff, 0xff, 0xff]
        #expect(converted == [0x30, 0x20, 0x10, 0x40])
    }

    @Test func fullResolutionDestinationSizesAreTightlyPacked() {
        for (width, height) in [(UInt32(1_920), UInt32(1_080)), (UInt32(3_840), UInt32(2_160))] {
            let byteCount = Int(width) * Int(height) * 4
            let source = [UInt8](repeating: 0, count: byteCount)
            let converted = convertClientShmToRGBAWithMetrics(
                pixels: source.span,
                width: width,
                height: height,
                drmFormat: DrmFourcc.xrgb8888,
                stride: width * 4)
            #expect(converted?.pixels.count == byteCount)
            #expect(converted?.metrics == ClientShmConversionMetrics(
                fullSizeOwnedAllocations: 1,
                ownedAllocationBytes: UInt64(byteCount),
                bytesCopied: UInt64(byteCount)))
        }
    }

    @Test func importFailureClosesDescriptorsBeforeAnyVulkanCall() {
        let descriptor = descriptorWithPipe()
        defer { _ = close(descriptor.writeFD) }

        if let unexpected = importDmaBufImage(
            device: fakeDevice,
            operations: nil,
            descriptor: descriptor.value)
        {
            Issue.record("missing Vulkan operations unexpectedly imported an image")
            _ = consume unexpected
        }
        #expect(fcntl(descriptor.readFD, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test func eachVulkanFailureRollsBackAcquiredResources() throws {
        let cases: [(DmaBufImportFailure, [String])] = [
            (.createImage, ["create-image"]),
            (.memoryProperties, [
                "create-image", "memory-requirements", "memory-properties",
                "destroy-image",
            ]),
            (.allocateMemory, [
                "create-image", "memory-requirements", "memory-properties",
                "allocate-memory", "destroy-image",
            ]),
            (.bindMemory, [
                "create-image", "memory-requirements", "memory-properties",
                "allocate-memory", "bind-memory", "free-memory",
                "destroy-image",
            ]),
        ]

        for (failure, expectedEvents) in cases {
            let descriptor = descriptorWithPipe()
            defer { _ = close(descriptor.writeFD) }
            FakeDmaBufImporter.reset(failure: failure)
            if let unexpected = importDmaBufImage(
                device: fakeDevice,
                operations: FakeDmaBufImporter.operations,
                descriptor: descriptor.value)
            {
                Issue.record("injected Vulkan failure unexpectedly imported an image")
                _ = consume unexpected
            }
            #expect(FakeDmaBufImporter.events == expectedEvents)
            #expect(fcntl(descriptor.readFD, F_GETFD) == -1)
            #expect(errno == EBADF)
        }
    }

    @Test func successfulImportTransfersFdAndDestroysImageBeforeMemory() throws {
        let descriptor = descriptorWithPipe()
        defer { _ = close(descriptor.writeFD) }
        FakeDmaBufImporter.reset(failure: .none)
        do {
            guard let image = importDmaBufImage(
                device: fakeDevice,
                operations: FakeDmaBufImporter.operations,
                descriptor: descriptor.value)
            else {
                Issue.record("valid injected Vulkan import failed")
                return
            }
            #expect(image.handle == FakeDmaBufImporter.image)
            #expect(fcntl(descriptor.readFD, F_GETFD) == -1)
            #expect(errno == EBADF)
        }
        #expect(FakeDmaBufImporter.events == [
            "create-image", "memory-requirements", "memory-properties",
            "allocate-memory", "bind-memory", "destroy-image", "free-memory",
        ])
    }

    @Test func invalidAndPartiallyAliasedPlaneLayoutsCloseEveryUniqueFd() {
        var pipes = [[Int32](repeating: -1, count: 2),
                     [Int32](repeating: -1, count: 2)]
        #expect(pipe(&pipes[0]) == 0)
        #expect(pipe(&pipes[1]) == 0)
        defer {
            _ = close(pipes[0][1])
            _ = close(pipes[1][1])
        }
        let descriptor = DmaBufImageDescriptor(
            fd: pipes[0][0],
            width: 16,
            height: 16,
            drmFormat: DrmFourcc.xrgb8888,
            modifier: 0,
            planes: [
                DmaBufPlane(fd: pipes[0][0], offset: 0, rowPitch: 64),
                DmaBufPlane(fd: pipes[0][0], offset: 1_024, rowPitch: 32),
                DmaBufPlane(fd: pipes[1][0], offset: 1_536, rowPitch: 32),
            ])
        FakeDmaBufImporter.reset(failure: .none)

        if let unexpected = importDmaBufImage(
            device: fakeDevice,
            operations: FakeDmaBufImporter.operations,
            descriptor: descriptor)
        {
            Issue.record("partially aliased plane layout was accepted")
            _ = consume unexpected
        }
        #expect(FakeDmaBufImporter.events.isEmpty)
        #expect(fcntl(pipes[0][0], F_GETFD) == -1)
        #expect(fcntl(pipes[1][0], F_GETFD) == -1)
    }

    private var fakeDevice: VkDevice {
        OpaquePointer(bitPattern: 0x3333)!
    }

    private func descriptorWithPipe() -> (
        value: DmaBufImageDescriptor,
        readFD: Int32,
        writeFD: Int32
    ) {
        var descriptors = [Int32](repeating: -1, count: 2)
        precondition(pipe(&descriptors) == 0)
        return (
            DmaBufImageDescriptor(
                fd: descriptors[0],
                width: 16,
                height: 16,
                drmFormat: DrmFourcc.xrgb8888,
                modifier: 0,
                planes: [
                    DmaBufPlane(offset: 0, rowPitch: 64),
                ]),
            descriptors[0],
            descriptors[1])
    }
}
