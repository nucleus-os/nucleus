import Foundation
import Glibc
import NucleusAndroidGfxstreamWorkerProtocolC
import NucleusAndroidGraphicsPlatform
import NucleusAndroidGpuBrokerCore
import NucleusAndroidIPCC

private enum GfxstreamWorkerBackendError: Error, CustomStringConvertible {
    case invalidRing(String)
    case systemCall(String, Int32)
    case worker(String)

    var description: String {
        switch self {
        case .invalidRing(let message):
            return message
        case .systemCall(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .worker(let message):
            return "gfxstream worker failed: \(message)"
        }
    }
}

final class GfxstreamWorkerBrokerRenderBackend: BrokerRenderBackend {
    private let executableURL: URL
    private var process: Process?
    private var controlDescriptor: Int32 = -1

    init(executablePath: String) {
        executableURL = URL(fileURLWithPath: executablePath)
    }

    func prepare(ring: AndroidBufferRing) throws {
        guard process == nil, controlDescriptor < 0 else {
            throw GfxstreamWorkerBackendError.invalidRing(
                "gfxstream worker backend was prepared more than once")
        }
        let buffers = ring.buffers.sorted { $0.id < $1.id }
        guard buffers.count ==
                Int(NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT),
              let first = buffers.first,
              buffers.allSatisfy({
                  $0.width == first.width &&
                      $0.height == first.height &&
                      $0.formatModifier == first.formatModifier &&
                      $0.planeCount == 1 &&
                      $0.id > 0 &&
                      $0.id <= UInt64(UInt32.max)
              })
        else {
            throw GfxstreamWorkerBackendError.invalidRing(
                "gfxstream worker requires three matching single-plane buffers")
        }

        var socketPair = [Int32](repeating: -1, count: 2)
        guard nucleus_android_ipc_socket_pair(&socketPair) == 0 else {
            throw systemError("socketpair")
        }
        let parentDescriptor = socketPair[0]
        let childDescriptor = socketPair[1]
        do {
            let child = Process()
            child.executableURL = executableURL
            child.arguments = ["--broker-worker"]
            child.standardInput = FileHandle(
                fileDescriptor: childDescriptor,
                closeOnDealloc: false)
            child.standardOutput = FileHandle.standardError
            try child.run()
            _ = close(childDescriptor)
            controlDescriptor = parentDescriptor
            process = child
        } catch {
            _ = close(parentDescriptor)
            _ = close(childDescriptor)
            throw error
        }

        var descriptors: [Int32] = []
        var planeLayouts: [(offset: UInt32, stride: UInt32)] = []
        defer {
            for descriptor in descriptors where descriptor >= 0 {
                _ = close(descriptor)
            }
        }
        do {
            for buffer in buffers {
                let plane = try buffer.exportPlane(at: 0)
                planeLayouts.append(
                    (offset: plane.offset, stride: plane.stride))
                descriptors.append(plane.takeFileDescriptor())
            }
            descriptors.append(try ring.acquireTimeline.exportFileDescriptor())
            for buffer in buffers {
                guard let timeline = ring.releaseTimeline(for: buffer.id) else {
                    throw GfxstreamWorkerBackendError.invalidRing(
                        "gfxstream worker buffer has no release timeline")
                }
                descriptors.append(try timeline.exportFileDescriptor())
            }
            guard descriptors.count ==
                    Int(NUCLEUS_ANDROID_GFXSTREAM_WORKER_DESCRIPTOR_COUNT)
            else {
                throw GfxstreamWorkerBackendError.invalidRing(
                    "gfxstream worker descriptor roles are incomplete")
            }

            var message = nucleus_android_gfxstream_worker_initialize()
            message.version = UInt32(NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION)
            message.type = UInt32(NUCLEUS_ANDROID_GFXSTREAM_WORKER_INITIALIZE.rawValue)
            message.byte_count = UInt32(
                MemoryLayout<nucleus_android_gfxstream_worker_initialize>.size)
            message.buffer_count = UInt32(buffers.count)
            message.width = first.width
            message.height = first.height
            message.drm_format = first.formatModifier.format
            message.drm_modifier = first.formatModifier.modifier
            try copyCString(
                ring.diagnostic.renderNode,
                into: &message.render_node)
            try copyCString(
                ring.diagnostic.vulkanDeviceUUID,
                into: &message.device_uuid)
            withUnsafeMutablePointer(to: &message.buffers) { tuple in
                tuple.withMemoryRebound(
                    to: nucleus_android_gfxstream_worker_buffer.self,
                    capacity: buffers.count
                ) { output in
                    for (index, buffer) in buffers.enumerated() {
                        output[index].color_buffer_handle = UInt32(buffer.id)
                        output[index].plane_offset =
                            planeLayouts[index].offset
                        output[index].plane_stride =
                            planeLayouts[index].stride
                    }
                }
            }
            guard message.buffers.0.plane_stride != 0,
                  message.buffers.1.plane_stride != 0,
                  message.buffers.2.plane_stride != 0
            else {
                throw GfxstreamWorkerBackendError.invalidRing(
                    "gfxstream worker could not read dma-buf plane layouts")
            }

            try send(message, descriptors: descriptors)
            let response = try receiveResponse()
            try requireSuccess(response, frameNumber: 0)
        } catch {
            stopWorker()
            throw error
        }
    }

    func render(
        buffer: AndroidGraphicsBuffer,
        frameNumber: UInt64,
        acquireTimeline: AndroidSyncobjTimeline,
        acquirePoint: UInt64,
        releaseTimeline: AndroidSyncobjTimeline?,
        releasePoint: UInt64
    ) throws {
        guard controlDescriptor >= 0,
              buffer.id > 0,
              buffer.id <= UInt64(UInt32.max),
              acquirePoint > 0,
              (releaseTimeline == nil) == (releasePoint == 0)
        else {
            throw GfxstreamWorkerBackendError.invalidRing(
                "gfxstream worker render request has invalid synchronization points")
        }
        var message = nucleus_android_gfxstream_worker_submit()
        message.version = UInt32(NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION)
        message.type = UInt32(NUCLEUS_ANDROID_GFXSTREAM_WORKER_SUBMIT.rawValue)
        message.byte_count = UInt32(
            MemoryLayout<nucleus_android_gfxstream_worker_submit>.size)
        message.color_buffer_handle = UInt32(buffer.id)
        message.frame_number = frameNumber
        message.acquire_point = acquirePoint
        message.release_point = releasePoint
        message.has_release_point = releaseTimeline == nil ? 0 : 1
        try send(message)
        try requireSuccess(
            try receiveResponse(),
            frameNumber: frameNumber)
    }

    deinit {
        stopWorker()
    }

    private func send<T>(
        _ message: T,
        descriptors: [Int32] = []
    ) throws {
        guard controlDescriptor >= 0 else {
            throw GfxstreamWorkerBackendError.worker(
                "control connection is not available")
        }
        let result = withUnsafeBytes(of: message) { bytes in
            descriptors.withUnsafeBufferPointer { descriptorBuffer in
                nucleus_android_ipc_send(
                    controlDescriptor,
                    bytes.baseAddress,
                    bytes.count,
                    descriptorBuffer.baseAddress,
                    descriptorBuffer.count)
            }
        }
        guard result == 0 else { throw systemError("sendmsg") }
    }

    private func receiveResponse()
        throws -> nucleus_android_gfxstream_worker_response
    {
        var response = nucleus_android_gfxstream_worker_response()
        var descriptorCount = 0
        let result = withUnsafeMutableBytes(of: &response) { bytes in
            nucleus_android_ipc_receive(
                controlDescriptor,
                bytes.baseAddress,
                bytes.count,
                nil,
                0,
                &descriptorCount)
        }
        guard result ==
                MemoryLayout<nucleus_android_gfxstream_worker_response>.size,
              descriptorCount == 0,
              response.version ==
                UInt32(NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION),
              response.type ==
                UInt32(NUCLEUS_ANDROID_GFXSTREAM_WORKER_RESPONSE.rawValue),
              response.byte_count ==
                UInt32(
                    MemoryLayout<
                        nucleus_android_gfxstream_worker_response
                    >.size)
        else {
            if result < 0 { throw systemError("recvmsg") }
            throw GfxstreamWorkerBackendError.worker(
                "worker returned an invalid response packet")
        }
        return response
    }

    private func requireSuccess(
        _ response: nucleus_android_gfxstream_worker_response,
        frameNumber: UInt64
    ) throws {
        guard response.frame_number == frameNumber else {
            throw GfxstreamWorkerBackendError.worker(
                "worker response named the wrong frame")
        }
        guard response.status == 0 else {
            throw GfxstreamWorkerBackendError.worker(
                string(from: response.error))
        }
    }

    private func stopWorker() {
        if controlDescriptor >= 0 {
            var shutdown = nucleus_android_gfxstream_worker_shutdown()
            shutdown.version = UInt32(
                NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION)
            shutdown.type = UInt32(
                NUCLEUS_ANDROID_GFXSTREAM_WORKER_SHUTDOWN.rawValue)
            shutdown.byte_count = UInt32(
                MemoryLayout<
                    nucleus_android_gfxstream_worker_shutdown
                >.size)
            try? send(shutdown)
            _ = close(controlDescriptor)
            controlDescriptor = -1
        }
        if let process {
            process.waitUntilExit()
        }
        process = nil
    }

    private func systemError(
        _ operation: String
    ) -> GfxstreamWorkerBackendError {
        .systemCall(operation, errno)
    }
}

private func copyCString<T>(
    _ string: String,
    into storage: inout T
) throws {
    let bytes = Array(string.utf8)
    guard bytes.count < MemoryLayout<T>.size else {
        throw GfxstreamWorkerBackendError.invalidRing(
            "gfxstream worker metadata string is too long")
    }
    withUnsafeMutableBytes(of: &storage) { output in
        output.initializeMemory(as: UInt8.self, repeating: 0)
        output.copyBytes(from: bytes)
    }
}

private func string<T>(from tuple: T) -> String {
    withUnsafeBytes(of: tuple) { bytes in
        guard let base = bytes.baseAddress else { return "" }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}
