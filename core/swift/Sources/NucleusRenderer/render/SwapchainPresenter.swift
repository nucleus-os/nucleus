import VulkanC
import Vulkan

/// The per-frame outcome exposed to platform adapters.
public enum SwapchainStatus: Sendable {
    case none, noSurface, invalidSurface, recreated, acquireFailed, renderFailed, presentFailed, posted
}

/// Generic Vulkan WSI backend shared by Android and the Wayland client shell.
///
/// Synchronization ownership is deliberately split:
/// - two frame slots own acquire semaphores and submission-completion fences;
/// - each swapchain image owns the binary semaphore consumed by presentation and
///   the `VK_KHR_swapchain_maintenance1` presentation-completion fence;
/// - retired swapchain generations stay alive until every armed presentation
///   fence signals. No steady-state queue/device idle operation is used.
@MainActor
public final class SwapchainPresenter: PresentationBackend {
    public let outputID: UInt64

    private final class FrameSlot {
        let acquireSemaphore: VkSemaphore
        let completionFence: VkFence
        var inFlight = false

        init(acquireSemaphore: VkSemaphore, completionFence: VkFence) {
            self.acquireSemaphore = acquireSemaphore
            self.completionFence = completionFence
        }
    }

    private final class Generation {
        let swapchain: VkSwapchainKHR
        let images: [VkImage?]
        let presentSemaphores: [VkSemaphore]
        let presentFences: [VkFence]
        var presentFenceArmed: [Bool]

        init(
            swapchain: VkSwapchainKHR, images: [VkImage?],
            presentSemaphores: [VkSemaphore], presentFences: [VkFence]
        ) {
            self.swapchain = swapchain
            self.images = images
            self.presentSemaphores = presentSemaphores
            self.presentFences = presentFences
            self.presentFenceArmed = [Bool](repeating: false, count: images.count)
        }
    }

    private struct Acquired {
        let generation: Generation
        let imageIndex: UInt32
        let slotIndex: Int
        var rendererSubmitted: Bool
        var completionEnqueued: Bool
    }

    private let instance: VkInstance
    private let instanceDispatch: VK.InstanceDispatch
    private let physicalDevice: VkPhysicalDevice
    private let queueFamily: UInt32
    private let device: VkDevice
    private let deviceDispatch: VK.DeviceDispatch
    private let queue: VkQueue

    private var surface: VkSurfaceKHR?
    private var surfaceOwner: VulkanSurface?
    private var activeGeneration: Generation?
    private var retiredGenerations: [Generation] = []
    private var frameSlots: [FrameSlot] = []
    private var nextFrameSlot = 0
    private var acquired: Acquired?

    private var extent = VkExtent2D(width: 0, height: 0)
    private var surfaceFormat = VkSurfaceFormatKHR()
    private var hasAlpha = false
    private var didTeardown = false

    public private(set) var lastStatus: SwapchainStatus = .none
    public private(set) var lastExtentWidth: Int32 = 0
    public private(set) var lastExtentHeight: Int32 = 0

    public init?(
        core: RenderCore, outputID: UInt64 = 1,
        surface: VulkanSurface
    ) {
        self.outputID = outputID
        self.instance = core.instanceHandle
        self.instanceDispatch = core.instanceDispatch
        self.physicalDevice = core.physicalDevice
        self.queueFamily = core.graphicsFamily
        self.device = core.deviceHandle
        self.deviceDispatch = core.deviceDispatch
        self.queue = core.graphicsQueue
        guard surface.instance == core.instanceHandle else { return nil }
        self.surface = surface.handle
        self.surfaceOwner = surface
        guard createFrameSlots(count: 2) else {
            destroyFrameSlots()
            return nil
        }
    }

    isolated deinit { teardown() }

    public func teardown() {
        guard !didTeardown else { return }
        didTeardown = true

        if acquired != nil { discardAcquiredTarget(outputID) }
        waitForFrameSlots()
        if let activeGeneration {
            waitForPresentations(activeGeneration)
            destroyGeneration(activeGeneration)
            self.activeGeneration = nil
        }
        for generation in retiredGenerations {
            waitForPresentations(generation)
            destroyGeneration(generation)
        }
        retiredGenerations.removeAll()
        destroyFrameSlots()
        surface = nil
        surfaceOwner = nil
    }

    private func createFrameSlots(count: Int) -> Bool {
        guard let createSemaphore = deviceDispatch.vkCreateSemaphore,
              let createFence = deviceDispatch.vkCreateFence
        else { return false }
        var semaphoreInfo = VkSemaphoreCreateInfo()
        semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT.rawValue

        for _ in 0..<count {
            var semaphore: VkSemaphore? = nil
            var fence: VkFence? = nil
            guard createSemaphore(device, &semaphoreInfo, nil, &semaphore) == VK_SUCCESS,
                  let semaphore,
                  createFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS,
                  let fence
            else {
                if let semaphore { deviceDispatch.vkDestroySemaphore?(device, semaphore, nil) }
                if let fence { deviceDispatch.vkDestroyFence?(device, fence, nil) }
                return false
            }
            frameSlots.append(FrameSlot(acquireSemaphore: semaphore, completionFence: fence))
        }
        return true
    }

    private func destroyFrameSlots() {
        for slot in frameSlots {
            deviceDispatch.vkDestroySemaphore?(device, slot.acquireSemaphore, nil)
            deviceDispatch.vkDestroyFence?(device, slot.completionFence, nil)
        }
        frameSlots.removeAll()
    }

    @discardableResult
    public func configure(
        width: Int32, height: Int32, hasAlpha: Bool
    ) -> Bool {
        self.hasAlpha = hasAlpha
        guard surface != nil else { lastStatus = .noSurface; return false }
        return createSwapchain(width: width, height: height)
    }

    private func createSwapchain(width: Int32, height: Int32) -> Bool {
        guard acquired == nil, let surface,
              let getCaps = instanceDispatch.vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
              let getFormats = instanceDispatch.vkGetPhysicalDeviceSurfaceFormatsKHR,
              let getSupport = instanceDispatch.vkGetPhysicalDeviceSurfaceSupportKHR,
              let createSwapchain = deviceDispatch.vkCreateSwapchainKHR,
              let getImages = deviceDispatch.vkGetSwapchainImagesKHR
        else { lastStatus = .invalidSurface; return false }

        var supported: VkBool32 = 0
        guard getSupport(physicalDevice, queueFamily, surface, &supported) == VK_SUCCESS,
              supported != 0
        else { lastStatus = .invalidSurface; return false }

        var caps = VkSurfaceCapabilitiesKHR()
        guard getCaps(physicalDevice, surface, &caps) == VK_SUCCESS else {
            lastStatus = .invalidSurface
            return false
        }
        var formatCount: UInt32 = 0
        guard getFormats(physicalDevice, surface, &formatCount, nil) == VK_SUCCESS,
              formatCount > 0
        else { lastStatus = .invalidSurface; return false }
        var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
        guard getFormats(physicalDevice, surface, &formatCount, &formats) == VK_SUCCESS else {
            lastStatus = .invalidSurface
            return false
        }
        let newFormat = formats.first {
            $0.format == VK_FORMAT_B8G8R8A8_UNORM && $0.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
        } ?? formats[0]

        let newExtent: VkExtent2D
        if caps.currentExtent.width != UInt32.max {
            newExtent = caps.currentExtent
        } else {
            newExtent = VkExtent2D(
                width: clampU32(UInt32(max(0, width)), caps.minImageExtent.width, caps.maxImageExtent.width),
                height: clampU32(UInt32(max(0, height)), caps.minImageExtent.height, caps.maxImageExtent.height))
        }
        var imageCount = caps.minImageCount + 1
        if caps.maxImageCount > 0 { imageCount = min(imageCount, caps.maxImageCount) }

        let wantPremultiplied = hasAlpha
            && (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR.rawValue) != 0
        var info = VkSwapchainCreateInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        info.surface = surface
        info.minImageCount = imageCount
        info.imageFormat = newFormat.format
        info.imageColorSpace = newFormat.colorSpace
        info.imageExtent = newExtent
        info.imageArrayLayers = 1
        info.imageUsage = VK.ImageUsageFlags.colorAttachmentBit.rawValue
            | VK.ImageUsageFlags.transferDstBit.rawValue
        info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
        info.preTransform = caps.currentTransform
        info.compositeAlpha = wantPremultiplied
            ? VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR : VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        info.presentMode = VK_PRESENT_MODE_FIFO_KHR
        info.clipped = 1
        info.oldSwapchain = activeGeneration?.swapchain

        var handle: VkSwapchainKHR? = nil
        guard createSwapchain(device, &info, nil, &handle) == VK_SUCCESS, let handle else {
            lastStatus = .invalidSurface
            return false
        }
        guard let generation = makeGeneration(swapchain: handle, getImages: getImages) else {
            deviceDispatch.vkDestroySwapchainKHR?(device, handle, nil)
            lastStatus = .invalidSurface
            return false
        }

        if let old = activeGeneration { retiredGenerations.append(old) }
        activeGeneration = generation
        extent = newExtent
        surfaceFormat = newFormat
        lastExtentWidth = Int32(truncatingIfNeeded: newExtent.width)
        lastExtentHeight = Int32(truncatingIfNeeded: newExtent.height)
        collectRetiredGenerations()
        return true
    }

    private func makeGeneration(
        swapchain: VkSwapchainKHR, getImages: PFN_vkGetSwapchainImagesKHR
    ) -> Generation? {
        guard let createSemaphore = deviceDispatch.vkCreateSemaphore,
              let createFence = deviceDispatch.vkCreateFence
        else { return nil }
        var count: UInt32 = 0
        guard getImages(device, swapchain, &count, nil) == VK_SUCCESS, count > 0 else { return nil }
        var images = [VkImage?](repeating: nil, count: Int(count))
        guard getImages(device, swapchain, &count, &images) == VK_SUCCESS else { return nil }

        var semaphoreInfo = VkSemaphoreCreateInfo()
        semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT.rawValue
        var semaphores: [VkSemaphore] = []
        var fences: [VkFence] = []
        for _ in images {
            var semaphore: VkSemaphore? = nil
            var fence: VkFence? = nil
            guard createSemaphore(device, &semaphoreInfo, nil, &semaphore) == VK_SUCCESS,
                  let semaphore,
                  createFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS,
                  let fence
            else {
                if let semaphore { deviceDispatch.vkDestroySemaphore?(device, semaphore, nil) }
                if let fence { deviceDispatch.vkDestroyFence?(device, fence, nil) }
                for value in semaphores { deviceDispatch.vkDestroySemaphore?(device, value, nil) }
                for value in fences { deviceDispatch.vkDestroyFence?(device, value, nil) }
                return nil
            }
            semaphores.append(semaphore)
            fences.append(fence)
        }
        return Generation(
            swapchain: swapchain, images: images,
            presentSemaphores: semaphores, presentFences: fences)
    }

    public func presentableOutputIDs() -> [UInt64] {
        surface != nil && activeGeneration != nil ? [outputID] : []
    }

    public func isReadyToPresent(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID, acquired == nil, activeGeneration != nil,
              !frameSlots.isEmpty, let getFenceStatus = deviceDispatch.vkGetFenceStatus
        else { return false }
        let slot = frameSlots[nextFrameSlot]
        return !slot.inFlight || getFenceStatus(device, slot.completionFence) == VK_SUCCESS
    }

    public func acquireTarget(_ outputID: UInt64) -> AcquiredFrameTarget? {
        guard outputID == self.outputID, acquired == nil,
              let generation = activeGeneration,
              let acquireNextImage = deviceDispatch.vkAcquireNextImageKHR,
              isReadyToPresent(outputID)
        else { return nil }
        collectRetiredGenerations()

        let slotIndex = nextFrameSlot
        let slot = frameSlots[slotIndex]
        var imageIndex: UInt32 = 0
        let result = acquireNextImage(
            device, generation.swapchain, 0, slot.acquireSemaphore, nil, &imageIndex)
        if result == VK_NOT_READY || result == VK_TIMEOUT {
            lastStatus = .none
            return nil
        }
        if result == VK_ERROR_OUT_OF_DATE_KHR {
            _ = createSwapchain(width: lastExtentWidth, height: lastExtentHeight)
            lastStatus = .recreated
            return nil
        }
        guard result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR,
              Int(imageIndex) < generation.images.count,
              let image = generation.images[Int(imageIndex)],
              let resetFences = deviceDispatch.vkResetFences
        else { lastStatus = .acquireFailed; return nil }

        var completionFence: VkFence? = slot.completionFence
        guard withUnsafePointer(to: &completionFence, {
            resetFences(device, 1, $0) == VK_SUCCESS
        }) else {
            releaseImage(generation: generation, imageIndex: imageIndex)
            lastStatus = .acquireFailed
            return nil
        }
        slot.inFlight = true
        acquired = Acquired(
            generation: generation, imageIndex: imageIndex,
            slotIndex: slotIndex, rendererSubmitted: false, completionEnqueued: false)
        nextFrameSlot = (slotIndex + 1) % frameSlots.count

        return AcquiredFrameTarget(
            image: image, width: lastExtentWidth, height: lastExtentHeight,
            format: surfaceFormat.format, tiling: VK_IMAGE_TILING_OPTIMAL,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED, queueFamily: queueFamily,
            hasAlpha: hasAlpha, kind: .swapchainColor,
            waitSemaphore: slot.acquireSemaphore,
            signalSemaphore: generation.presentSemaphores[Int(imageIndex)])
    }

    public func didSubmitTarget(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID, var acquired,
              let submit = deviceDispatch.vkQueueSubmit
        else { return false }
        let slot = frameSlots[acquired.slotIndex]
        acquired.rendererSubmitted = true
        self.acquired = acquired
        guard submit(queue, 0, nil, slot.completionFence) == VK_SUCCESS else {
            lastStatus = .renderFailed
            return false
        }
        acquired.completionEnqueued = true
        self.acquired = acquired
        return true
    }

    public func present(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID, let acquired, acquired.completionEnqueued,
              let present = deviceDispatch.vkQueuePresentKHR
        else { lastStatus = .presentFailed; return false }
        self.acquired = nil

        let generation = acquired.generation
        let index = Int(acquired.imageIndex)
        let presentFence = generation.presentFences[index]
        if generation.presentFenceArmed[index] {
            // Reacquiring this image guarantees its preceding presentation will
            // complete, but the acquire semaphore may be signaled after the host
            // acquire call returns. Wait here, after CPU recording overlapped that
            // completion, before resetting the presentation-owned fence.
            waitForFence(presentFence)
            generation.presentFenceArmed[index] = false
        }
        var presentFenceOptional: VkFence? = presentFence
        guard let resetFences = deviceDispatch.vkResetFences,
              withUnsafePointer(to: &presentFenceOptional, {
            resetFences(device, 1, $0) == VK_SUCCESS
        }) else {
            waitForFence(frameSlots[acquired.slotIndex].completionFence)
            releaseImage(generation: generation, imageIndex: acquired.imageIndex)
            lastStatus = .presentFailed
            return false
        }

        var fenceInfo = VkSwapchainPresentFenceInfoKHR()
        fenceInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_KHR
        fenceInfo.swapchainCount = 1
        var waitSemaphore: VkSemaphore? = generation.presentSemaphores[index]
        var swapchain: VkSwapchainKHR? = generation.swapchain
        var imageIndex = acquired.imageIndex
        var result = VK_SUCCESS
        withUnsafePointer(to: &presentFenceOptional) { fencePointer in
            fenceInfo.pFences = fencePointer
            withUnsafePointer(to: &fenceInfo) { fenceInfoPointer in
                withUnsafePointer(to: &waitSemaphore) { waitPointer in
                    withUnsafePointer(to: &swapchain) { swapchainPointer in
                        withUnsafePointer(to: &imageIndex) { indexPointer in
                            var info = VkPresentInfoKHR()
                            info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                            info.pNext = UnsafeRawPointer(fenceInfoPointer)
                            info.waitSemaphoreCount = 1
                            info.pWaitSemaphores = waitPointer
                            info.swapchainCount = 1
                            info.pSwapchains = swapchainPointer
                            info.pImageIndices = indexPointer
                            result = present(queue, &info)
                        }
                    }
                }
            }
        }

        if result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR {
            generation.presentFenceArmed[index] = true
        }
        if result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR {
            if result == VK_ERROR_OUT_OF_DATE_KHR {
                waitForFence(frameSlots[acquired.slotIndex].completionFence)
                releaseImage(generation: generation, imageIndex: acquired.imageIndex)
            }
            _ = createSwapchain(width: lastExtentWidth, height: lastExtentHeight)
            lastStatus = .recreated
            return result == VK_SUBOPTIMAL_KHR
        }
        guard result == VK_SUCCESS else {
            waitForFence(frameSlots[acquired.slotIndex].completionFence)
            releaseImage(generation: generation, imageIndex: acquired.imageIndex)
            lastStatus = .presentFailed
            return false
        }
        lastStatus = .posted
        return true
    }

    public func discardAcquiredTarget(_ outputID: UInt64) {
        guard outputID == self.outputID, let acquired else { return }
        self.acquired = nil
        let slot = frameSlots[acquired.slotIndex]

        if acquired.rendererSubmitted && !acquired.completionEnqueued {
            // The renderer already queued a wait on the acquire semaphore, so it
            // must not be waited a second time. This is an exceptional recovery
            // path for failure to enqueue the fence-only completion marker.
            _ = deviceDispatch.vkQueueWaitIdle?(queue)
            slot.inFlight = false
        } else if !acquired.completionEnqueued {
            guard let submit = deviceDispatch.vkQueueSubmit else {
                lastStatus = .renderFailed
                return
            }
            var waitSemaphore: VkSemaphore? = slot.acquireSemaphore
            var waitStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue
            let submitted = withUnsafePointer(to: &waitSemaphore) { waitPointer in
                withUnsafePointer(to: &waitStage) { stagePointer in
                    var info = VkSubmitInfo()
                    info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                    info.waitSemaphoreCount = 1
                    info.pWaitSemaphores = waitPointer
                    info.pWaitDstStageMask = stagePointer
                    return submit(queue, 1, &info, slot.completionFence) == VK_SUCCESS
                }
            }
            guard submitted else { lastStatus = .renderFailed; return }
        }
        if slot.inFlight { waitForFence(slot.completionFence) }
        releaseImage(generation: acquired.generation, imageIndex: acquired.imageIndex)
    }

    public func didPresentFrame() { collectRetiredGenerations() }
    public func pauseSession() {}
    public func resumeSession() {}

    private func releaseImage(generation: Generation, imageIndex: UInt32) {
        guard let release = deviceDispatch.vkReleaseSwapchainImagesKHR else {
            lastStatus = .renderFailed
            return
        }
        var index = imageIndex
        withUnsafePointer(to: &index) { pointer in
            var info = VkReleaseSwapchainImagesInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_RELEASE_SWAPCHAIN_IMAGES_INFO_KHR
            info.swapchain = generation.swapchain
            info.imageIndexCount = 1
            info.pImageIndices = pointer
            if release(device, &info) != VK_SUCCESS { lastStatus = .renderFailed }
        }
    }

    private func collectRetiredGenerations() {
        guard let getFenceStatus = deviceDispatch.vkGetFenceStatus else { return }
        var survivors: [Generation] = []
        for generation in retiredGenerations {
            let complete = generation.presentFences.indices.allSatisfy {
                !generation.presentFenceArmed[$0]
                    || getFenceStatus(device, generation.presentFences[$0]) == VK_SUCCESS
            }
            if complete { destroyGeneration(generation) } else { survivors.append(generation) }
        }
        retiredGenerations = survivors
    }

    private func destroyGeneration(_ generation: Generation) {
        for semaphore in generation.presentSemaphores {
            deviceDispatch.vkDestroySemaphore?(device, semaphore, nil)
        }
        for fence in generation.presentFences {
            deviceDispatch.vkDestroyFence?(device, fence, nil)
        }
        deviceDispatch.vkDestroySwapchainKHR?(device, generation.swapchain, nil)
    }

    private func waitForFrameSlots() {
        for slot in frameSlots where slot.inFlight { waitForFence(slot.completionFence) }
    }

    private func waitForPresentations(_ generation: Generation) {
        for index in generation.presentFences.indices where generation.presentFenceArmed[index] {
            waitForFence(generation.presentFences[index])
        }
    }

    private func waitForFence(_ fence: VkFence) {
        guard let wait = deviceDispatch.vkWaitForFences else { return }
        var optional: VkFence? = fence
        withUnsafePointer(to: &optional) { _ = wait(device, 1, $0, 1, UInt64.max) }
    }
}

private func clampU32(_ value: UInt32, _ minimum: UInt32, _ maximum: UInt32) -> UInt32 {
    min(max(value, minimum), maximum)
}
