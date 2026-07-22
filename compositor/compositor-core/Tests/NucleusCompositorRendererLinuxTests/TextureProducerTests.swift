import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
import NucleusRenderModel
import NucleusTypes
@testable import NucleusRenderer

// accumulation + the same-content suppression decision (hardware-independent),
// plus the shadow rasterizer + repaint-vs-suppress
// counting over a real Graphite recorder (best-effort GPU, asserts nothing
// hardware-conditional).
@Suite struct TextureProducerTests {
    @Test func producerWorkStats() {
        var a = ProducerWorkStats()
        #expect(!a.hasWork && a.total == 0, "stats-empty")
        a.paintRepaint = 2
        a.shadowRepaint = 3
        #expect(a.total == 5 && a.hasWork, "stats-total")
        var b = ProducerWorkStats()
        b.shadowRepaint = 1
        a.merge(b)
        #expect(a.shadowRepaint == 4, "stats-merge")
    }

    @Test func suppressionDecision() {
        // Hardware-independent via raster upload.
        let registry = TextureRegistry()
        let producer = TextureProducer(registry: registry)
        let key = ProducerCacheKey(
            layerId: 5, revision: 1, width: 2, height: 2, kind: .paint)
        #expect(producer.handle(for: key) == nil, "producer-cache-starts-empty")
        #expect(key != ProducerCacheKey(
            layerId: 5, revision: 1, width: 3, height: 2, kind: .paint),
            "raster-width-is-cache-identity")
        #expect(key != ProducerCacheKey(
            layerId: 5, revision: 1, width: 2, height: 3, kind: .paint),
            "raster-height-is-cache-identity")
        let trafficLightsAtOnePointFive = ProducerCacheKey(
            layerId: 5, revision: 1,
            width: Int32((72.0 * 1.5).rounded(.up)),
            height: Int32((28.0 * 1.5).rounded(.up)), kind: .paint)
        #expect(trafficLightsAtOnePointFive.width == 108)
        #expect(trafficLightsAtOnePointFive.height == 42)

        let oldAtOnePointFive = ProducerCacheKey(
            layerId: 5, revision: 1, width: 108, height: 42, kind: .paint)
        let oldAtTwo = ProducerCacheKey(
            layerId: 5, revision: 1, width: 144, height: 56, kind: .paint)
        let current = ProducerCacheKey(
            layerId: 5, revision: 2, width: 108, height: 42, kind: .paint)
        #expect(TextureProducer.supersededKeys(
            in: [oldAtOnePointFive, oldAtTwo, current],
            replacing: current) == [oldAtOnePointFive, oldAtTwo])

        let shadow = ProducerCacheKey(
            layerId: 5, revision: 1, width: 108, height: 42, kind: .shadow)
        #expect(shadow != current, "shadow-and-paint-have-independent-cache-namespaces")
    }

    // Best-effort GPU: decoration rasterization + counting over a real Graphite
    // recorder. Hardware-gated, so it asserts nothing hardware-conditional.
    @Test(.disabled("requires a live GPU/Vulkan device")) func decorationRasterizationBestEffort() {
        let registry = TextureRegistry()
        let producer = TextureProducer(registry: registry)
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]

        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "TextureProducerTests",
            contract: contract, enableValidation: false
        ) else { return }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instance.handle, dispatch: instance.dispatch, contract: contract
        ) else { return }
        guard let device = DeviceOwner.create(
            selection: selection, instanceDispatch: instance.dispatch,
            contract: contract
        ) else { return }
        guard let queue = device.queue(family: selection.graphicsQueueFamily) else { return }

        withCStringArray(contract.deviceExtensions) { extPtr, extCount in
            var desc = nucleus.skia.VulkanContextDescriptor()
            desc.instance = UnsafeMutableRawPointer(instance.handle)
            desc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            desc.device = UnsafeMutableRawPointer(device.handle)
            desc.queue = UnsafeMutableRawPointer(queue)
            desc.graphicsQueueIndex = selection.graphicsQueueFamily
            desc.maxApiVersion = VkRequirements.minimumApiVersion.raw
            desc.deviceExtensions = extPtr
            desc.deviceExtensionCount = extCount

            let context = nucleus.skia.makeGraphiteVulkanContext(desc)
            guard context.isValid() else { return }
            let recorder = context.makeRecorder()
            guard recorder.isValid() else { return }

            var shadowColor = nucleus.skia.Color()
            shadowColor.a = 0.6
            let shadow = ShadowDecoration(
                width: 64, height: 48,
                shapeRect: PlanRect(x: 12, y: 12, w: 40, h: 24),
                cornerRadii: (8, 7, 6, 5), blurSigma: 4, color: shadowColor)

            // First produce rasterizes; same revision suppresses; new revision
            // repaints into the same handle.
            guard let sh = producer.produceShadow(recorder: recorder, layerId: 10, revision: 1, shadow: shadow) else {
                return
            }
            _ = producer.drainStats()
            _ = producer.produceShadow(recorder: recorder, layerId: 10, revision: 1, shadow: shadow)
            _ = producer.drainStats()
            _ = producer.produceShadow(recorder: recorder, layerId: 10, revision: 2, shadow: shadow)
            _ = producer.drainStats()
            _ = sh

            // A path command's geometry rides the payload blob.
            var linePayload: [UInt8] = []
            PaintPayload.append(
                to: &linePayload, verbs: [.move, .line], points: [0, 17, 24, 17])

            let paintCommands = [
                PaintDrawCommand(kind: .rect, x: 0, y: 0, w: 24, h: 18, color: (1, 0, 0, 1)),
                PaintDrawCommand(kind: .roundedRect, x: 4, y: 4, w: 12, h: 8, radius: 3, color: (0, 1, 0, 0.8)),
                PaintDrawCommand(
                    kind: .path, x: 0, y: 17, w: 24, h: 0, strokeWidth: 2, color: (0, 0, 1, 1),
                    payloadOffset: 0, payloadLength: UInt32(linePayload.count), stroke: true),
                PaintDrawCommand(kind: .image, x: 2, y: 2, w: 8, h: 8, imageHandle: 77),
                PaintDrawCommand(kind: .textLayout, x: 1, y: 1, w: 20, h: 10, color: (1, 1, 1, 1), textLayoutHandle: 123),
            ]
            let paintImage = pixels.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(2, 2, $0.baseAddress, $0.count)
            }
            let paintHandle = producer.producePaintCommands(
                recorder: recorder, layerId: 12, revision: 1,
                commands: paintCommands, payload: linePayload,
                authoredWidth: 24, authoredHeight: 18,
                contentWidth: 48, contentHeight: 36,
                resolveImage: { handle in handle == 77 ? paintImage : nil },
                resolveEffect: { _ in nil })
            _ = producer.drainStats()
            let paintHandle2 = producer.producePaintCommands(
                recorder: recorder, layerId: 12, revision: 1,
                commands: paintCommands, payload: linePayload,
                authoredWidth: 24, authoredHeight: 18,
                contentWidth: 48, contentHeight: 36,
                resolveImage: { handle in handle == 77 ? paintImage : nil },
                resolveEffect: { _ in nil })
            _ = paintHandle
            _ = paintHandle2
            _ = producer.drainStats()

            let recording = recorder.snapRecording()
            _ = submitGraphiteAndWait(
                context: context, recording: recording, serial: 1)

            // GPU-backed images must not outlive the context: drop them here.
            registry.clear()
        }
    }
}
