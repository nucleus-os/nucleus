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
/// Main-actor isolation serializes every handle access. The presenter owns all
/// synchronization objects and generations until their completion fences signal.
@safe public final class SwapchainPresenter: PresentationBackend {
    public let outputID: UInt64

    /// Graphite requires input-attachment usage on every Vulkan color render
    /// target in addition to ordinary color-attachment usage.
    static let requiredImageUsage: VK.ImageUsageFlags = [
        .colorAttachmentBit,
        .inputAttachmentBit,
        .transferDstBit,
    ]

    /// Owns one semaphore/fence pair until presenter teardown.
    @safe private final class FrameSlot {
        let acquireSemaphore: VkSemaphore
        let completionFence: VkFence
        var inFlight = false

        init(acquireSemaphore: VkSemaphore, completionFence: VkFence) {
            unsafe self.acquireSemaphore = acquireSemaphore
            unsafe self.completionFence = completionFence
        }
    }

    /// Owns one swapchain generation and its per-image synchronization handles.
    @safe private final class Generation {
        let swapchain: VkSwapchainKHR
        let images: [VkImage?]
        let presentSemaphores: [VkSemaphore]
        let presentFences: [VkFence]
        var presentFenceArmed: [Bool]

        init(
            swapchain: VkSwapchainKHR, images: [VkImage?],
            presentSemaphores: [VkSemaphore], presentFences: [VkFence]
        ) {
            unsafe self.swapchain = swapchain
            unsafe self.images = images
            unsafe self.presentSemaphores = presentSemaphores
            unsafe self.presentFences = presentFences
            self.presentFenceArmed = unsafe [Bool](repeating: false, count: images.count)
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
        unsafe self.instance = core.instanceHandle
        self.instanceDispatch = core.instanceDispatch
        unsafe self.physicalDevice = core.physicalDevice
        self.queueFamily = core.graphicsFamily
        unsafe self.device = core.deviceHandle
        self.deviceDispatch = core.deviceDispatch
        unsafe self.queue = core.graphicsQueue
        guard unsafe surface.instance == core.instanceHandle else { return nil }
        unsafe self.surface = surface.handle
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
        unsafe surface = nil
        surfaceOwner = nil
    }

    private func createFrameSlots(count: Int) -> Bool {
        guard let createSemaphore = unsafe deviceDispatch.vkCreateSemaphore,
              let createFence = unsafe deviceDispatch.vkCreateFence
        else { return false }
        var semaphoreInfo = unsafe VkSemaphoreCreateInfo()
        unsafe semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var fenceInfo = unsafe VkFenceCreateInfo()
        unsafe fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        unsafe fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT.rawValue

        for _ in 0..<count {
            var semaphore: VkSemaphore? = nil
            var fence: VkFence? = nil
            guard unsafe createSemaphore(device, &semaphoreInfo, nil, &semaphore) == VK_SUCCESS,
                  let semaphore = unsafe semaphore,
                  unsafe createFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS,
                  let fence = unsafe fence
            else {
                if let semaphore = unsafe semaphore {
                    unsafe deviceDispatch.vkDestroySemaphore?(device, semaphore, nil)
                }
                if let fence = unsafe fence {
                    unsafe deviceDispatch.vkDestroyFence?(device, fence, nil)
                }
                return false
            }
            unsafe frameSlots.append(FrameSlot(acquireSemaphore: semaphore, completionFence: fence))
        }
        return true
    }

    private func destroyFrameSlots() {
        for slot in frameSlots {
            unsafe deviceDispatch.vkDestroySemaphore?(device, slot.acquireSemaphore, nil)
            unsafe deviceDispatch.vkDestroyFence?(device, slot.completionFence, nil)
        }
        frameSlots.removeAll()
    }

    @discardableResult
    public func configure(
        width: Int32, height: Int32, hasAlpha: Bool
    ) -> Bool {
        self.hasAlpha = hasAlpha
        guard unsafe surface != nil else { lastStatus = .noSurface; return false }
        return createSwapchain(width: width, height: height)
    }

    private func createSwapchain(width: Int32, height: Int32) -> Bool {
        guard acquired == nil, let surface = unsafe surface,
              let getCaps = unsafe instanceDispatch.vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
              let getFormats = unsafe instanceDispatch.vkGetPhysicalDeviceSurfaceFormatsKHR,
              let getSupport = unsafe instanceDispatch.vkGetPhysicalDeviceSurfaceSupportKHR,
              let createSwapchain = unsafe deviceDispatch.vkCreateSwapchainKHR,
              let getImages = unsafe deviceDispatch.vkGetSwapchainImagesKHR
        else { lastStatus = .invalidSurface; return false }

        var supported: VkBool32 = 0
        guard unsafe getSupport(physicalDevice, queueFamily, surface, &supported) == VK_SUCCESS,
              supported != 0
        else { lastStatus = .invalidSurface; return false }

        var caps = VkSurfaceCapabilitiesKHR()
        guard unsafe getCaps(physicalDevice, surface, &caps) == VK_SUCCESS else {
            lastStatus = .invalidSurface
            return false
        }
        var formatCount: UInt32 = 0
        guard unsafe getFormats(physicalDevice, surface, &formatCount, nil) == VK_SUCCESS,
              formatCount > 0
        else { lastStatus = .invalidSurface; return false }
        var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
        guard unsafe getFormats(physicalDevice, surface, &formatCount, &formats) == VK_SUCCESS else {
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
        let requiredUsage = Self.requiredImageUsage.rawValue
        guard caps.supportedUsageFlags & requiredUsage == requiredUsage else {
            lastStatus = .invalidSurface
            return false
        }

        let wantPremultiplied = hasAlpha
            && (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR.rawValue) != 0
        var info = unsafe VkSwapchainCreateInfoKHR()
        unsafe info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        unsafe info.surface = surface
        unsafe info.minImageCount = imageCount
        unsafe info.imageFormat = newFormat.format
        unsafe info.imageColorSpace = newFormat.colorSpace
        unsafe info.imageExtent = newExtent
        unsafe info.imageArrayLayers = 1
        unsafe info.imageUsage = requiredUsage
        unsafe info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
        unsafe info.preTransform = caps.currentTransform
        unsafe info.compositeAlpha = wantPremultiplied
            ? VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR : VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        unsafe info.presentMode = VK_PRESENT_MODE_FIFO_KHR
        unsafe info.clipped = 1
        unsafe info.oldSwapchain = activeGeneration?.swapchain

        var handle: VkSwapchainKHR? = nil
        guard unsafe createSwapchain(device, &info, nil, &handle) == VK_SUCCESS,
              let handle = unsafe handle
        else {
            lastStatus = .invalidSurface
            return false
        }
        guard let generation = unsafe makeGeneration(swapchain: handle, getImages: getImages) else {
            unsafe deviceDispatch.vkDestroySwapchainKHR?(device, handle, nil)
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
        guard let createSemaphore = unsafe deviceDispatch.vkCreateSemaphore,
              let createFence = unsafe deviceDispatch.vkCreateFence
        else { return nil }
        var count: UInt32 = 0
        guard unsafe getImages(device, swapchain, &count, nil) == VK_SUCCESS, count > 0 else { return nil }
        var images = unsafe [VkImage?](repeating: nil, count: Int(count))
        guard unsafe getImages(device, swapchain, &count, &images) == VK_SUCCESS else { return nil }

        var semaphoreInfo = unsafe VkSemaphoreCreateInfo()
        unsafe semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var fenceInfo = unsafe VkFenceCreateInfo()
        unsafe fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        unsafe fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT.rawValue
        var semaphores: [VkSemaphore] = unsafe []
        var fences: [VkFence] = unsafe []
        for unsafe _ in unsafe images {
            var semaphore: VkSemaphore? = nil
            var fence: VkFence? = nil
            guard unsafe createSemaphore(device, &semaphoreInfo, nil, &semaphore) == VK_SUCCESS,
                  let semaphore = unsafe semaphore,
                  unsafe createFence(device, &fenceInfo, nil, &fence) == VK_SUCCESS,
                  let fence = unsafe fence
            else {
                if let semaphore = unsafe semaphore {
                    unsafe deviceDispatch.vkDestroySemaphore?(device, semaphore, nil)
                }
                if let fence = unsafe fence {
                    unsafe deviceDispatch.vkDestroyFence?(device, fence, nil)
                }
                for unsafe value in unsafe semaphores {
                    unsafe deviceDispatch.vkDestroySemaphore?(device, value, nil)
                }
                for unsafe value in unsafe fences {
                    unsafe deviceDispatch.vkDestroyFence?(device, value, nil)
                }
                return nil
            }
            unsafe semaphores.append(semaphore)
            unsafe fences.append(fence)
        }
        return unsafe Generation(
            swapchain: swapchain, images: images,
            presentSemaphores: semaphores, presentFences: fences)
    }

    public func presentableOutputIDs() -> [UInt64] {
        unsafe surface != nil && activeGeneration != nil ? [outputID] : []
    }

    public func isReadyToPresent(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID, acquired == nil, activeGeneration != nil,
              !frameSlots.isEmpty, let getFenceStatus = unsafe deviceDispatch.vkGetFenceStatus
        else { return false }
        let slot = frameSlots[nextFrameSlot]
        return unsafe !slot.inFlight || getFenceStatus(device, slot.completionFence) == VK_SUCCESS
    }

    public func acquireTarget(_ outputID: UInt64) -> AcquiredFrameTarget? {
        guard outputID == self.outputID, acquired == nil,
              let generation = activeGeneration,
              let acquireNextImage = unsafe deviceDispatch.vkAcquireNextImageKHR,
              isReadyToPresent(outputID)
        else { return nil }
        collectRetiredGenerations()

        let slotIndex = nextFrameSlot
        let slot = frameSlots[slotIndex]
        var imageIndex: UInt32 = 0
        let result = unsafe acquireNextImage(
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
              unsafe Int(imageIndex) < generation.images.count,
              let image = unsafe generation.images[Int(imageIndex)],
              let resetFences = unsafe deviceDispatch.vkResetFences
        else { lastStatus = .acquireFailed; return nil }

        var completionFence: VkFence? = unsafe slot.completionFence
        guard withUnsafePointer(to: &completionFence, {
            unsafe resetFences(device, 1, $0) == VK_SUCCESS
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

        return unsafe AcquiredFrameTarget(
            image: image, width: lastExtentWidth, height: lastExtentHeight,
            format: surfaceFormat.format, tiling: VK_IMAGE_TILING_OPTIMAL,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: Self.requiredImageUsage,
            queueFamily: queueFamily,
            hasAlpha: hasAlpha, kind: .swapchainColor,
            waitSemaphore: slot.acquireSemaphore,
            signalSemaphore: generation.presentSemaphores[Int(imageIndex)])
    }

    public func didSubmitTarget(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID, var acquired,
              let submit = unsafe deviceDispatch.vkQueueSubmit
        else { return false }
        let slot = frameSlots[acquired.slotIndex]
        acquired.rendererSubmitted = true
        self.acquired = acquired
        guard unsafe submit(queue, 0, nil, slot.completionFence) == VK_SUCCESS else {
            lastStatus = .renderFailed
            return false
        }
        acquired.completionEnqueued = true
        self.acquired = acquired
        return true
    }

    public func present(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID, let acquired, acquired.completionEnqueued,
              let present = unsafe deviceDispatch.vkQueuePresentKHR
        else { lastStatus = .presentFailed; return false }
        self.acquired = nil

        let generation = acquired.generation
        let index = Int(acquired.imageIndex)
        let presentFence = unsafe generation.presentFences[index]
        if generation.presentFenceArmed[index] {
            // Reacquiring this image guarantees its preceding presentation will
            // complete, but the acquire semaphore may be signaled after the host
            // acquire call returns. Wait here, after CPU recording overlapped that
            // completion, before resetting the presentation-owned fence.
            unsafe waitForFence(presentFence)
            generation.presentFenceArmed[index] = false
        }
        var presentFenceOptional: VkFence? = unsafe presentFence
        guard let resetFences = unsafe deviceDispatch.vkResetFences,
              withUnsafePointer(to: &presentFenceOptional, {
            unsafe resetFences(device, 1, $0) == VK_SUCCESS
        }) else {
            unsafe waitForFence(frameSlots[acquired.slotIndex].completionFence)
            releaseImage(generation: generation, imageIndex: acquired.imageIndex)
            lastStatus = .presentFailed
            return false
        }

        var fenceInfo = unsafe VkSwapchainPresentFenceInfoKHR()
        unsafe fenceInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_KHR
        unsafe fenceInfo.swapchainCount = 1
        var waitSemaphore: VkSemaphore? = unsafe generation.presentSemaphores[index]
        var swapchain: VkSwapchainKHR? = unsafe generation.swapchain
        var imageIndex = acquired.imageIndex
        var result = VK_SUCCESS
        withUnsafePointer(to: &presentFenceOptional) { fencePointer in
            unsafe fenceInfo.pFences = fencePointer
            withUnsafePointer(to: &fenceInfo) { fenceInfoPointer in
                withUnsafePointer(to: &waitSemaphore) { waitPointer in
                    withUnsafePointer(to: &swapchain) { swapchainPointer in
                        withUnsafePointer(to: &imageIndex) { indexPointer in
                            var info = unsafe VkPresentInfoKHR()
                            unsafe info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                            unsafe info.pNext = UnsafeRawPointer(fenceInfoPointer)
                            unsafe info.waitSemaphoreCount = 1
                            unsafe info.pWaitSemaphores = waitPointer
                            unsafe info.swapchainCount = 1
                            unsafe info.pSwapchains = swapchainPointer
                            unsafe info.pImageIndices = indexPointer
                            result = unsafe present(queue, &info)
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
                unsafe waitForFence(frameSlots[acquired.slotIndex].completionFence)
                releaseImage(generation: generation, imageIndex: acquired.imageIndex)
            }
            _ = createSwapchain(width: lastExtentWidth, height: lastExtentHeight)
            lastStatus = .recreated
            return result == VK_SUBOPTIMAL_KHR
        }
        guard result == VK_SUCCESS else {
            unsafe waitForFence(frameSlots[acquired.slotIndex].completionFence)
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
            _ = unsafe deviceDispatch.vkQueueWaitIdle?(queue)
            slot.inFlight = false
        } else if !acquired.completionEnqueued {
            guard let submit = unsafe deviceDispatch.vkQueueSubmit else {
                lastStatus = .renderFailed
                return
            }
            var waitSemaphore: VkSemaphore? = unsafe slot.acquireSemaphore
            var waitStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue
            let submitted = withUnsafePointer(to: &waitSemaphore) { waitPointer in
                withUnsafePointer(to: &waitStage) { stagePointer in
                    var info = unsafe VkSubmitInfo()
                    unsafe info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                    unsafe info.waitSemaphoreCount = 1
                    unsafe info.pWaitSemaphores = waitPointer
                    unsafe info.pWaitDstStageMask = stagePointer
                    return unsafe submit(queue, 1, &info, slot.completionFence) == VK_SUCCESS
                }
            }
            guard submitted else { lastStatus = .renderFailed; return }
        }
        if slot.inFlight { unsafe waitForFence(slot.completionFence) }
        releaseImage(generation: acquired.generation, imageIndex: acquired.imageIndex)
    }

    public func didPresentFrame() { collectRetiredGenerations() }
    public func pauseSession() {}
    public func resumeSession() {}

    private func releaseImage(generation: Generation, imageIndex: UInt32) {
        guard let release = unsafe deviceDispatch.vkReleaseSwapchainImagesKHR else {
            lastStatus = .renderFailed
            return
        }
        var index = imageIndex
        withUnsafePointer(to: &index) { pointer in
            var info = unsafe VkReleaseSwapchainImagesInfoKHR()
            unsafe info.sType = VK_STRUCTURE_TYPE_RELEASE_SWAPCHAIN_IMAGES_INFO_KHR
            unsafe info.swapchain = generation.swapchain
            unsafe info.imageIndexCount = 1
            unsafe info.pImageIndices = pointer
            if unsafe release(device, &info) != VK_SUCCESS { lastStatus = .renderFailed }
        }
    }

    private func collectRetiredGenerations() {
        guard let getFenceStatus = unsafe deviceDispatch.vkGetFenceStatus else { return }
        var survivors: [Generation] = []
        for generation in retiredGenerations {
            let complete = unsafe generation.presentFences.indices.allSatisfy {
                unsafe !generation.presentFenceArmed[$0]
                    || getFenceStatus(device, generation.presentFences[$0]) == VK_SUCCESS
            }
            if complete { destroyGeneration(generation) } else { survivors.append(generation) }
        }
        retiredGenerations = survivors
    }

    private func destroyGeneration(_ generation: Generation) {
        for unsafe semaphore in unsafe generation.presentSemaphores {
            unsafe deviceDispatch.vkDestroySemaphore?(device, semaphore, nil)
        }
        for unsafe fence in unsafe generation.presentFences {
            unsafe deviceDispatch.vkDestroyFence?(device, fence, nil)
        }
        unsafe deviceDispatch.vkDestroySwapchainKHR?(device, generation.swapchain, nil)
    }

    private func waitForFrameSlots() {
        for slot in frameSlots where slot.inFlight { unsafe waitForFence(slot.completionFence) }
    }

    private func waitForPresentations(_ generation: Generation) {
        for index in unsafe generation.presentFences.indices
        where generation.presentFenceArmed[index]
        {
            unsafe waitForFence(generation.presentFences[index])
        }
    }

    private func waitForFence(_ fence: VkFence) {
        guard let wait = unsafe deviceDispatch.vkWaitForFences else { return }
        var optional: VkFence? = unsafe fence
        withUnsafePointer(to: &optional) { _ = unsafe wait(device, 1, $0, 1, UInt64.max) }
    }
}

private func clampU32(_ value: UInt32, _ minimum: UInt32, _ maximum: UInt32) -> UInt32 {
    min(max(value, minimum), maximum)
}
