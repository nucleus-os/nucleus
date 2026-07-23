#define _GNU_SOURCE
#include "NucleusAndroidDrmC.h"

#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include <xf86drm.h>
#include <drm_fourcc.h>

struct nucleus_android_submission {
    VkCommandPool command_pool;
    VkFence fence;
    VkSemaphore wait_semaphore;
    VkSemaphore signal_semaphore;
    struct nucleus_android_submission *next;
};

struct nucleus_android_gpu {
    int drm_fd;
    struct gbm_device *gbm;
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family;
    PFN_vkGetMemoryFdPropertiesKHR get_memory_fd_properties;
    PFN_vkImportSemaphoreFdKHR import_semaphore_fd;
    PFN_vkGetSemaphoreFdKHR get_semaphore_fd;
    struct nucleus_android_gpu_diagnostic diagnostic;
    VkPhysicalDeviceMemoryProperties memory_properties;
    struct nucleus_android_submission *submissions;
    struct nucleus_android_gpu_buffer *retired_buffers;
};

struct nucleus_android_gpu_buffer {
    nucleus_android_gpu *gpu;
    struct gbm_bo *bo;
    VkImage image;
    VkDeviceMemory memory;
    uint32_t width;
    uint32_t height;
    uint32_t drm_format;
    uint64_t modifier;
    uint32_t plane_count;
    VkImageLayout layout;
    struct nucleus_android_gpu_buffer *retired_next;
};

struct nucleus_android_syncobj_timeline {
    nucleus_android_gpu *gpu;
    uint32_t handle;
};

struct nucleus_android_syncobj_waiter {
    int drm_fd;
    int event_fd;
    uint32_t handle;
};

static void nucleus_android_error(char *output, size_t capacity, const char *message) {
    if (!output || capacity == 0) return;
    snprintf(output, capacity, "%s", message ? message : "unknown graphics failure");
}

static void nucleus_android_errno_error(
    char *output,
    size_t capacity,
    const char *operation) {
    if (!output || capacity == 0) return;
    snprintf(output, capacity, "%s: %s", operation, strerror(errno));
}

static void nucleus_android_vulkan_error(
    char *output,
    size_t capacity,
    const char *operation,
    VkResult result) {
    if (!output || capacity == 0) return;
    snprintf(output, capacity, "%s failed with VkResult %d", operation, (int)result);
}

static void nucleus_android_copy(char *output, size_t capacity, const char *input) {
    if (!output || capacity == 0) return;
    snprintf(output, capacity, "%s", input ? input : "");
}

static void nucleus_android_uuid_hex(
    char output[NUCLEUS_ANDROID_GPU_UUID_HEX_MAX],
    const uint8_t uuid[VK_UUID_SIZE]) {
    static const char digits[] = "0123456789abcdef";
    for (size_t index = 0; index < VK_UUID_SIZE; ++index) {
        output[index * 2] = digits[uuid[index] >> 4];
        output[index * 2 + 1] = digits[uuid[index] & 0x0f];
    }
    output[VK_UUID_SIZE * 2] = '\0';
}

static int nucleus_android_stat_device(
    const char *path,
    struct nucleus_android_device_id *output) {
    struct stat status;
    if (!path || !output || stat(path, &status) < 0 || !S_ISCHR(status.st_mode)) return -1;
    output->major = (uint32_t)major(status.st_rdev);
    output->minor = (uint32_t)minor(status.st_rdev);
    return 0;
}

int nucleus_android_drm_device_id(
    const char *path,
    struct nucleus_android_device_id *output) {
    return nucleus_android_stat_device(path, output);
}

int nucleus_android_drm_device_id_from_native(
    const void *bytes,
    size_t byte_count,
    struct nucleus_android_device_id *output) {
    if (!bytes || !output || byte_count != sizeof(dev_t)) {
        errno = EINVAL;
        return -1;
    }
    dev_t device;
    memcpy(&device, bytes, sizeof(device));
    output->major = (uint32_t)major(device);
    output->minor = (uint32_t)minor(device);
    return 0;
}

int nucleus_android_drm_enumerate(
    struct nucleus_android_drm_candidate *output,
    size_t capacity) {
    drmDevicePtr devices[64] = {0};
    int count = drmGetDevices2(0, devices, 64);
    if (count < 0) return -1;
    int filled = count < 64 ? count : 64;
    size_t written = 0;
    for (int index = 0; index < filled; ++index) {
        drmDevicePtr device = devices[index];
        if (!device || device->bustype != DRM_BUS_PCI || !device->businfo.pci ||
            !device->deviceinfo.pci ||
            (device->available_nodes & (1 << DRM_NODE_RENDER)) == 0 ||
            !device->nodes[DRM_NODE_RENDER]) {
            continue;
        }
        if (written >= capacity || !output) {
            ++written;
            continue;
        }
        struct nucleus_android_drm_candidate *candidate = &output[written++];
        memset(candidate, 0, sizeof(*candidate));
        nucleus_android_copy(
            candidate->render_path,
            sizeof(candidate->render_path),
            device->nodes[DRM_NODE_RENDER]);
        (void)nucleus_android_stat_device(
            candidate->render_path,
            &candidate->render_device);
        if ((device->available_nodes & (1 << DRM_NODE_PRIMARY)) != 0 &&
            device->nodes[DRM_NODE_PRIMARY]) {
            nucleus_android_copy(
                candidate->primary_path,
                sizeof(candidate->primary_path),
                device->nodes[DRM_NODE_PRIMARY]);
            (void)nucleus_android_stat_device(
                candidate->primary_path,
                &candidate->primary_device);
        }
        candidate->pci_domain = device->businfo.pci->domain;
        candidate->pci_bus = device->businfo.pci->bus;
        candidate->pci_device = device->businfo.pci->dev;
        candidate->pci_function = device->businfo.pci->func;
        candidate->vendor_id = device->deviceinfo.pci->vendor_id;
        candidate->product_id = device->deviceinfo.pci->device_id;
    }
    drmFreeDevices(devices, filled);
    if (written > (size_t)INT32_MAX) {
        errno = EOVERFLOW;
        return -1;
    }
    return (int)written;
}

static bool nucleus_android_has_extension(
    const VkExtensionProperties *extensions,
    uint32_t count,
    const char *name) {
    for (uint32_t index = 0; index < count; ++index) {
        if (strcmp(extensions[index].extensionName, name) == 0) return true;
    }
    return false;
}

static VkFormat nucleus_android_vk_format(uint32_t format) {
    switch (format) {
    case DRM_FORMAT_XRGB8888:
    case DRM_FORMAT_ARGB8888:
        return VK_FORMAT_B8G8R8A8_UNORM;
    case DRM_FORMAT_XBGR8888:
    case DRM_FORMAT_ABGR8888:
        return VK_FORMAT_R8G8B8A8_UNORM;
    default:
        return VK_FORMAT_UNDEFINED;
    }
}

static void nucleus_android_collect_submissions(nucleus_android_gpu *gpu) {
    if (!gpu || !gpu->device) return;
    struct nucleus_android_submission **link = &gpu->submissions;
    while (*link) {
        struct nucleus_android_submission *submission = *link;
        VkResult status = vkGetFenceStatus(gpu->device, submission->fence);
        if (status != VK_SUCCESS) {
            link = &submission->next;
            continue;
        }
        *link = submission->next;
        if (submission->wait_semaphore) {
            vkDestroySemaphore(gpu->device, submission->wait_semaphore, NULL);
        }
        if (submission->signal_semaphore) {
            vkDestroySemaphore(gpu->device, submission->signal_semaphore, NULL);
        }
        vkDestroyFence(gpu->device, submission->fence, NULL);
        vkDestroyCommandPool(gpu->device, submission->command_pool, NULL);
        free(submission);
    }
}

static bool nucleus_android_select_physical_device(
    nucleus_android_gpu *gpu,
    uint32_t target_major,
    uint32_t target_minor,
    char *error_message,
    size_t error_capacity) {
    uint32_t count = 0;
    VkResult result = vkEnumeratePhysicalDevices(gpu->instance, &count, NULL);
    if (result != VK_SUCCESS || count == 0) {
        nucleus_android_vulkan_error(
            error_message, error_capacity, "vkEnumeratePhysicalDevices", result);
        return false;
    }
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) {
        nucleus_android_error(error_message, error_capacity, "out of memory");
        return false;
    }
    result = vkEnumeratePhysicalDevices(gpu->instance, &count, devices);
    if (result != VK_SUCCESS) {
        free(devices);
        nucleus_android_vulkan_error(
            error_message, error_capacity, "vkEnumeratePhysicalDevices", result);
        return false;
    }

    bool matched = false;
    for (uint32_t index = 0; index < count && !matched; ++index) {
        VkPhysicalDeviceDrmPropertiesEXT drm = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT};
        VkPhysicalDeviceDriverProperties driver = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
            .pNext = &drm};
        VkPhysicalDeviceIDProperties identity = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES,
            .pNext = &driver};
        VkPhysicalDeviceProperties2 properties = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &identity};
        vkGetPhysicalDeviceProperties2(devices[index], &properties);
        if (!drm.hasRender || drm.renderMajor != (int64_t)target_major ||
            drm.renderMinor != (int64_t)target_minor ||
            properties.properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) {
            continue;
        }

        uint32_t extension_count = 0;
        result = vkEnumerateDeviceExtensionProperties(
            devices[index], NULL, &extension_count, NULL);
        if (result != VK_SUCCESS) continue;
        VkExtensionProperties *extensions = calloc(extension_count, sizeof(*extensions));
        if (!extensions) continue;
        result = vkEnumerateDeviceExtensionProperties(
            devices[index], NULL, &extension_count, extensions);
        const char *required[] = {
            VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
            VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
            VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
        };
        bool supports_all = result == VK_SUCCESS;
        for (size_t required_index = 0;
             required_index < sizeof(required) / sizeof(required[0]);
             ++required_index) {
            supports_all = supports_all && nucleus_android_has_extension(
                extensions, extension_count, required[required_index]);
        }
        free(extensions);
        if (!supports_all) continue;

        gpu->physical_device = devices[index];
        gpu->diagnostic.api_version = properties.properties.apiVersion;
        gpu->diagnostic.driver_id = (uint32_t)driver.driverID;
        gpu->diagnostic.device_type = (uint32_t)properties.properties.deviceType;
        gpu->diagnostic.hardware_driver = 1;
        nucleus_android_copy(
            gpu->diagnostic.device_name,
            sizeof(gpu->diagnostic.device_name),
            properties.properties.deviceName);
        nucleus_android_copy(
            gpu->diagnostic.driver_name,
            sizeof(gpu->diagnostic.driver_name),
            driver.driverName);
        nucleus_android_copy(
            gpu->diagnostic.driver_info,
            sizeof(gpu->diagnostic.driver_info),
            driver.driverInfo);
        nucleus_android_uuid_hex(
            gpu->diagnostic.device_uuid,
            identity.deviceUUID);
        matched = true;
    }
    free(devices);
    if (!matched) {
        nucleus_android_error(
            error_message,
            error_capacity,
            "no hardware Vulkan device matched the DRM render node and required external-memory extensions");
    }
    return matched;
}

static bool nucleus_android_create_device(
    nucleus_android_gpu *gpu,
    char *error_message,
    size_t error_capacity) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu->physical_device, &count, NULL);
    VkQueueFamilyProperties *properties = calloc(count, sizeof(*properties));
    if (!properties) {
        nucleus_android_error(error_message, error_capacity, "out of memory");
        return false;
    }
    vkGetPhysicalDeviceQueueFamilyProperties(gpu->physical_device, &count, properties);
    bool found = false;
    for (uint32_t index = 0; index < count; ++index) {
        if ((properties[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
            gpu->queue_family = index;
            found = true;
            break;
        }
    }
    free(properties);
    if (!found) {
        nucleus_android_error(error_message, error_capacity, "Vulkan device has no graphics queue");
        return false;
    }

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = gpu->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority};
    const char *extensions[] = {
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
        VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    };
    VkDeviceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
        .enabledExtensionCount = sizeof(extensions) / sizeof(extensions[0]),
        .ppEnabledExtensionNames = extensions};
    VkResult result = vkCreateDevice(
        gpu->physical_device, &create_info, NULL, &gpu->device);
    if (result != VK_SUCCESS) {
        nucleus_android_vulkan_error(
            error_message, error_capacity, "vkCreateDevice", result);
        return false;
    }
    vkGetDeviceQueue(gpu->device, gpu->queue_family, 0, &gpu->queue);
    gpu->get_memory_fd_properties = (PFN_vkGetMemoryFdPropertiesKHR)
        vkGetDeviceProcAddr(gpu->device, "vkGetMemoryFdPropertiesKHR");
    gpu->import_semaphore_fd = (PFN_vkImportSemaphoreFdKHR)
        vkGetDeviceProcAddr(gpu->device, "vkImportSemaphoreFdKHR");
    gpu->get_semaphore_fd = (PFN_vkGetSemaphoreFdKHR)
        vkGetDeviceProcAddr(gpu->device, "vkGetSemaphoreFdKHR");
    if (!gpu->get_memory_fd_properties || !gpu->import_semaphore_fd ||
        !gpu->get_semaphore_fd) {
        nucleus_android_error(
            error_message, error_capacity, "Vulkan external-fd entry points are unavailable");
        return false;
    }
    vkGetPhysicalDeviceMemoryProperties(gpu->physical_device, &gpu->memory_properties);
    return true;
}

nucleus_android_gpu *nucleus_android_gpu_create(
    const char *render_path,
    char *error_message,
    size_t error_capacity) {
    if (!render_path) {
        errno = EINVAL;
        nucleus_android_error(error_message, error_capacity, "render path is required");
        return NULL;
    }
    nucleus_android_gpu *gpu = calloc(1, sizeof(*gpu));
    if (!gpu) {
        nucleus_android_error(error_message, error_capacity, "out of memory");
        return NULL;
    }
    gpu->drm_fd = -1;
    gpu->drm_fd = open(render_path, O_RDWR | O_CLOEXEC);
    if (gpu->drm_fd < 0) {
        nucleus_android_errno_error(error_message, error_capacity, "open render node");
        nucleus_android_gpu_destroy(gpu);
        return NULL;
    }
    struct nucleus_android_device_id render_device;
    if (nucleus_android_stat_device(render_path, &render_device) < 0) {
        nucleus_android_error(error_message, error_capacity, "render node has no device identity");
        nucleus_android_gpu_destroy(gpu);
        return NULL;
    }
    gpu->gbm = gbm_create_device(gpu->drm_fd);
    if (!gpu->gbm) {
        nucleus_android_errno_error(error_message, error_capacity, "gbm_create_device");
        nucleus_android_gpu_destroy(gpu);
        return NULL;
    }
    nucleus_android_copy(
        gpu->diagnostic.gbm_backend,
        sizeof(gpu->diagnostic.gbm_backend),
        gbm_device_get_backend_name(gpu->gbm));

    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Nucleus Android GPU Broker",
        .applicationVersion = 1,
        .pEngineName = "Nucleus",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_3};
    const char *validation_layer = "VK_LAYER_KHRONOS_validation";
    const char *validation_environment = getenv("NUCLEUS_ANDROID_VULKAN_VALIDATION");
    bool enable_validation = validation_environment &&
        strcmp(validation_environment, "1") == 0;
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledLayerCount = enable_validation ? 1u : 0u,
        .ppEnabledLayerNames = enable_validation ? &validation_layer : NULL};
    VkResult result = vkCreateInstance(&instance_info, NULL, &gpu->instance);
    if (result != VK_SUCCESS) {
        nucleus_android_vulkan_error(error_message, error_capacity, "vkCreateInstance", result);
        nucleus_android_gpu_destroy(gpu);
        return NULL;
    }
    if (!nucleus_android_select_physical_device(
            gpu, render_device.major, render_device.minor, error_message, error_capacity) ||
        !nucleus_android_create_device(gpu, error_message, error_capacity)) {
        nucleus_android_gpu_destroy(gpu);
        return NULL;
    }
    return gpu;
}

void nucleus_android_gpu_destroy(nucleus_android_gpu *gpu) {
    if (!gpu) return;
    if (gpu->device) {
        (void)vkDeviceWaitIdle(gpu->device);
        nucleus_android_collect_submissions(gpu);
        while (gpu->submissions) {
            struct nucleus_android_submission *submission = gpu->submissions;
            gpu->submissions = submission->next;
            if (submission->wait_semaphore) {
                vkDestroySemaphore(gpu->device, submission->wait_semaphore, NULL);
            }
            if (submission->signal_semaphore) {
                vkDestroySemaphore(gpu->device, submission->signal_semaphore, NULL);
            }
            vkDestroyFence(gpu->device, submission->fence, NULL);
            vkDestroyCommandPool(gpu->device, submission->command_pool, NULL);
            free(submission);
        }
        while (gpu->retired_buffers) {
            nucleus_android_gpu_buffer *buffer = gpu->retired_buffers;
            gpu->retired_buffers = buffer->retired_next;
            if (buffer->image) vkDestroyImage(gpu->device, buffer->image, NULL);
            if (buffer->memory) vkFreeMemory(gpu->device, buffer->memory, NULL);
            if (buffer->bo) gbm_bo_destroy(buffer->bo);
            free(buffer);
        }
        vkDestroyDevice(gpu->device, NULL);
    }
    if (gpu->instance) vkDestroyInstance(gpu->instance, NULL);
    if (gpu->gbm) gbm_device_destroy(gpu->gbm);
    if (gpu->drm_fd >= 0) close(gpu->drm_fd);
    free(gpu);
}

int nucleus_android_gpu_get_diagnostic(
    nucleus_android_gpu *gpu,
    struct nucleus_android_gpu_diagnostic *output) {
    if (!gpu || !output) {
        errno = EINVAL;
        return -1;
    }
    *output = gpu->diagnostic;
    return 0;
}

int nucleus_android_gpu_format_modifier_properties(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    uint64_t modifier,
    uint32_t *output_plane_count,
    uint64_t *output_features) {
    if (!gpu || !output_plane_count || !output_features) {
        errno = EINVAL;
        return -1;
    }
    VkFormat format = nucleus_android_vk_format(drm_format);
    if (format == VK_FORMAT_UNDEFINED) return 0;
    VkDrmFormatModifierPropertiesListEXT list = {
        .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT};
    VkFormatProperties2 properties = {
        .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = &list};
    vkGetPhysicalDeviceFormatProperties2(gpu->physical_device, format, &properties);
    if (list.drmFormatModifierCount == 0) return 0;
    VkDrmFormatModifierPropertiesEXT *modifiers =
        calloc(list.drmFormatModifierCount, sizeof(*modifiers));
    if (!modifiers) return 0;
    list.pDrmFormatModifierProperties = modifiers;
    vkGetPhysicalDeviceFormatProperties2(gpu->physical_device, format, &properties);
    int found = 0;
    for (uint32_t index = 0; index < list.drmFormatModifierCount; ++index) {
        if (modifiers[index].drmFormatModifier == modifier) {
            *output_plane_count = modifiers[index].drmFormatModifierPlaneCount;
            *output_features = modifiers[index].drmFormatModifierTilingFeatures;
            found = 1;
            break;
        }
    }
    free(modifiers);
    return found;
}

int nucleus_android_gpu_list_format_modifiers(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    struct nucleus_android_format_modifier_properties *output,
    size_t capacity) {
    if (!gpu) {
        errno = EINVAL;
        return -1;
    }
    VkFormat format = nucleus_android_vk_format(drm_format);
    if (format == VK_FORMAT_UNDEFINED) return 0;
    VkDrmFormatModifierPropertiesListEXT list = {
        .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT};
    VkFormatProperties2 properties = {
        .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = &list};
    vkGetPhysicalDeviceFormatProperties2(gpu->physical_device, format, &properties);
    if (!output || capacity == 0) return (int)list.drmFormatModifierCount;
    VkDrmFormatModifierPropertiesEXT *modifiers =
        calloc(list.drmFormatModifierCount, sizeof(*modifiers));
    if (!modifiers) return -1;
    list.pDrmFormatModifierProperties = modifiers;
    vkGetPhysicalDeviceFormatProperties2(gpu->physical_device, format, &properties);
    size_t copied = list.drmFormatModifierCount < capacity
        ? list.drmFormatModifierCount
        : capacity;
    for (size_t index = 0; index < copied; ++index) {
        output[index].modifier = modifiers[index].drmFormatModifier;
        output[index].features = modifiers[index].drmFormatModifierTilingFeatures;
        output[index].plane_count = modifiers[index].drmFormatModifierPlaneCount;
    }
    free(modifiers);
    return (int)list.drmFormatModifierCount;
}

int nucleus_android_gpu_supports_format_modifier(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    uint64_t modifier) {
    uint32_t plane_count = 0;
    uint64_t features = 0;
    int found = nucleus_android_gpu_format_modifier_properties(
        gpu,
        drm_format,
        modifier,
        &plane_count,
        &features);
    const VkFormatFeatureFlags required =
        VK_FORMAT_FEATURE_TRANSFER_DST_BIT | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
    return found == 1 && plane_count == 1 &&
        (features & required) == required;
}

int nucleus_android_gpu_preferred_modifier(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    uint64_t *output_modifier) {
    if (!gpu || !output_modifier) {
        errno = EINVAL;
        return -1;
    }
    struct gbm_bo *bo = gbm_bo_create(
        gpu->gbm,
        64,
        64,
        drm_format,
        GBM_BO_USE_RENDERING);
    if (!bo) return -1;
    *output_modifier = gbm_bo_get_modifier(bo);
    gbm_bo_destroy(bo);
    return 0;
}

static bool nucleus_android_memory_type(
    nucleus_android_gpu *gpu,
    uint32_t bits,
    uint32_t *output) {
    for (uint32_t index = 0; index < gpu->memory_properties.memoryTypeCount; ++index) {
        if ((bits & (1u << index)) != 0 &&
            (gpu->memory_properties.memoryTypes[index].propertyFlags &
             VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
            *output = index;
            return true;
        }
    }
    for (uint32_t index = 0; index < gpu->memory_properties.memoryTypeCount; ++index) {
        if ((bits & (1u << index)) != 0) {
            *output = index;
            return true;
        }
    }
    return false;
}

nucleus_android_gpu_buffer *nucleus_android_gpu_buffer_create(
    nucleus_android_gpu *gpu,
    uint32_t width,
    uint32_t height,
    uint32_t drm_format,
    uint64_t modifier,
    int scanout,
    char *error_message,
    size_t error_capacity) {
    if (!gpu || width == 0 || height == 0 ||
        !nucleus_android_gpu_supports_format_modifier(gpu, drm_format, modifier)) {
        errno = EINVAL;
        nucleus_android_error(error_message, error_capacity, "unsupported allocation request");
        return NULL;
    }
    uint32_t flags = GBM_BO_USE_RENDERING;
    if (scanout) flags |= GBM_BO_USE_SCANOUT;
    struct gbm_bo *bo = gbm_bo_create_with_modifiers2(
        gpu->gbm, width, height, drm_format, &modifier, 1, flags);
    if (!bo) {
        nucleus_android_errno_error(error_message, error_capacity, "GBM modifier allocation");
        return NULL;
    }
    uint32_t plane_count = gbm_bo_get_plane_count(bo);
    if (plane_count != 1) {
        gbm_bo_destroy(bo);
        nucleus_android_error(
            error_message, error_capacity, "only single-plane RGB dma-bufs are supported");
        return NULL;
    }
    int import_fd = gbm_bo_get_fd_for_plane(bo, 0);
    if (import_fd < 0) {
        gbm_bo_destroy(bo);
        nucleus_android_errno_error(error_message, error_capacity, "GBM dma-buf export");
        return NULL;
    }

    VkFormat vk_format = nucleus_android_vk_format(drm_format);
    VkSubresourceLayout plane_layout = {
        .offset = gbm_bo_get_offset(bo, 0),
        .rowPitch = gbm_bo_get_stride_for_plane(bo, 0)};
    VkImageDrmFormatModifierExplicitCreateInfoEXT modifier_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .drmFormatModifier = modifier,
        .drmFormatModifierPlaneCount = 1,
        .pPlaneLayouts = &plane_layout};
    VkExternalMemoryImageCreateInfo external_info = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &modifier_info,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT};
    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external_info,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = vk_format,
        .extent = {.width = width, .height = height, .depth = 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage image = VK_NULL_HANDLE;
    VkResult result = vkCreateImage(gpu->device, &image_info, NULL, &image);
    if (result != VK_SUCCESS) {
        close(import_fd);
        gbm_bo_destroy(bo);
        nucleus_android_vulkan_error(error_message, error_capacity, "vkCreateImage", result);
        return NULL;
    }

    VkMemoryFdPropertiesKHR fd_properties = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR};
    result = gpu->get_memory_fd_properties(
        gpu->device,
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        import_fd,
        &fd_properties);
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(gpu->device, image, &requirements);
    uint32_t memory_type = 0;
    uint32_t memory_bits = requirements.memoryTypeBits & fd_properties.memoryTypeBits;
    if (result != VK_SUCCESS ||
        !nucleus_android_memory_type(gpu, memory_bits, &memory_type)) {
        close(import_fd);
        vkDestroyImage(gpu->device, image, NULL);
        gbm_bo_destroy(bo);
        nucleus_android_error(
            error_message, error_capacity, "dma-buf has no Vulkan-compatible memory type");
        return NULL;
    }

    VkMemoryDedicatedAllocateInfo dedicated = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        .image = image};
    VkImportMemoryFdInfoKHR import = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .pNext = &dedicated,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        .fd = import_fd};
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type};
    VkDeviceMemory memory = VK_NULL_HANDLE;
    result = vkAllocateMemory(gpu->device, &allocate, NULL, &memory);
    if (result != VK_SUCCESS) {
        close(import_fd);
        vkDestroyImage(gpu->device, image, NULL);
        gbm_bo_destroy(bo);
        nucleus_android_vulkan_error(error_message, error_capacity, "vkAllocateMemory", result);
        return NULL;
    }
    result = vkBindImageMemory(gpu->device, image, memory, 0);
    if (result != VK_SUCCESS) {
        vkFreeMemory(gpu->device, memory, NULL);
        vkDestroyImage(gpu->device, image, NULL);
        gbm_bo_destroy(bo);
        nucleus_android_vulkan_error(error_message, error_capacity, "vkBindImageMemory", result);
        return NULL;
    }

    nucleus_android_gpu_buffer *buffer = calloc(1, sizeof(*buffer));
    if (!buffer) {
        vkFreeMemory(gpu->device, memory, NULL);
        vkDestroyImage(gpu->device, image, NULL);
        gbm_bo_destroy(bo);
        nucleus_android_error(error_message, error_capacity, "out of memory");
        return NULL;
    }
    buffer->gpu = gpu;
    buffer->bo = bo;
    buffer->image = image;
    buffer->memory = memory;
    buffer->width = width;
    buffer->height = height;
    buffer->drm_format = drm_format;
    buffer->modifier = modifier;
    buffer->plane_count = plane_count;
    buffer->layout = VK_IMAGE_LAYOUT_UNDEFINED;
    return buffer;
}

void nucleus_android_gpu_buffer_destroy(nucleus_android_gpu_buffer *buffer) {
    if (!buffer) return;
    buffer->retired_next = buffer->gpu->retired_buffers;
    buffer->gpu->retired_buffers = buffer;
}

uint32_t nucleus_android_gpu_buffer_plane_count(nucleus_android_gpu_buffer *buffer) {
    return buffer ? buffer->plane_count : 0;
}

int nucleus_android_gpu_buffer_export_plane(
    nucleus_android_gpu_buffer *buffer,
    uint32_t plane_index,
    struct nucleus_android_dmabuf_plane *output_layout) {
    if (!buffer || !output_layout || plane_index >= buffer->plane_count) {
        errno = EINVAL;
        return -1;
    }
    int fd = gbm_bo_get_fd_for_plane(buffer->bo, (int)plane_index);
    if (fd < 0) return -1;
    output_layout->offset = gbm_bo_get_offset(buffer->bo, (int)plane_index);
    output_layout->stride = gbm_bo_get_stride_for_plane(buffer->bo, (int)plane_index);
    return fd;
}

nucleus_android_syncobj_timeline *nucleus_android_syncobj_timeline_create(
    nucleus_android_gpu *gpu) {
    if (!gpu) {
        errno = EINVAL;
        return NULL;
    }
    nucleus_android_syncobj_timeline *timeline = calloc(1, sizeof(*timeline));
    if (!timeline) return NULL;
    timeline->gpu = gpu;
    if (drmSyncobjCreate(gpu->drm_fd, 0, &timeline->handle) != 0 ||
        timeline->handle == 0) {
        free(timeline);
        return NULL;
    }
    return timeline;
}

nucleus_android_syncobj_timeline *nucleus_android_syncobj_timeline_import_fd(
    nucleus_android_gpu *gpu,
    int timeline_fd) {
    if (!gpu || timeline_fd < 0) {
        errno = EINVAL;
        return NULL;
    }
    nucleus_android_syncobj_timeline *timeline = calloc(1, sizeof(*timeline));
    if (!timeline) return NULL;
    timeline->gpu = gpu;
    if (drmSyncobjFDToHandle(
            gpu->drm_fd,
            timeline_fd,
            &timeline->handle) != 0 ||
        timeline->handle == 0) {
        free(timeline);
        return NULL;
    }
    return timeline;
}

void nucleus_android_syncobj_timeline_destroy(
    nucleus_android_syncobj_timeline *timeline) {
    if (!timeline) return;
    (void)drmSyncobjDestroy(timeline->gpu->drm_fd, timeline->handle);
    free(timeline);
}

int nucleus_android_syncobj_timeline_export_fd(
    nucleus_android_syncobj_timeline *timeline) {
    if (!timeline) {
        errno = EINVAL;
        return -1;
    }
    int fd = -1;
    if (drmSyncobjHandleToFD(timeline->gpu->drm_fd, timeline->handle, &fd) != 0) return -1;
    return fd;
}

int nucleus_android_syncobj_timeline_signal(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point) {
    if (!timeline) {
        errno = EINVAL;
        return -1;
    }
    uint32_t handle = timeline->handle;
    return drmSyncobjTimelineSignal(timeline->gpu->drm_fd, &handle, &point, 1);
}

int nucleus_android_syncobj_timeline_is_signaled(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point) {
    if (!timeline) {
        errno = EINVAL;
        return -1;
    }
    uint32_t handle = timeline->handle;
    uint32_t first = 0;
    int result = drmSyncobjTimelineWait(
        timeline->gpu->drm_fd,
        &handle,
        &point,
        1,
        0,
        DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL | DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT,
        &first);
    if (result == 0) return 1;
    if (errno == ETIME) return 0;
    return -1;
}

nucleus_android_syncobj_waiter *nucleus_android_syncobj_waiter_create(
    const char *render_path,
    int timeline_fd) {
    if (!render_path || timeline_fd < 0) {
        errno = EINVAL;
        return NULL;
    }
    nucleus_android_syncobj_waiter *waiter = calloc(1, sizeof(*waiter));
    if (!waiter) return NULL;
    waiter->drm_fd = -1;
    waiter->event_fd = -1;
    waiter->drm_fd = open(render_path, O_RDWR | O_CLOEXEC);
    if (waiter->drm_fd < 0 ||
        drmSyncobjFDToHandle(waiter->drm_fd, timeline_fd, &waiter->handle) != 0 ||
        waiter->handle == 0) {
        nucleus_android_syncobj_waiter_destroy(waiter);
        return NULL;
    }
    waiter->event_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (waiter->event_fd < 0) {
        nucleus_android_syncobj_waiter_destroy(waiter);
        return NULL;
    }
    return waiter;
}

void nucleus_android_syncobj_waiter_destroy(nucleus_android_syncobj_waiter *waiter) {
    if (!waiter) return;
    if (waiter->handle != 0 && waiter->drm_fd >= 0) {
        (void)drmSyncobjDestroy(waiter->drm_fd, waiter->handle);
    }
    if (waiter->event_fd >= 0) close(waiter->event_fd);
    if (waiter->drm_fd >= 0) close(waiter->drm_fd);
    free(waiter);
}

int nucleus_android_syncobj_waiter_is_signaled(
    nucleus_android_syncobj_waiter *waiter,
    uint64_t point) {
    if (!waiter) {
        errno = EINVAL;
        return -1;
    }
    uint32_t handle = waiter->handle;
    uint32_t first = 0;
    int result = drmSyncobjTimelineWait(
        waiter->drm_fd,
        &handle,
        &point,
        1,
        0,
        DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL | DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT,
        &first);
    if (result == 0) return 1;
    if (errno == ETIME) return 0;
    return -1;
}

int nucleus_android_syncobj_waiter_arm(
    nucleus_android_syncobj_waiter *waiter,
    uint64_t point) {
    if (!waiter) {
        errno = EINVAL;
        return -1;
    }
    if (nucleus_android_syncobj_waiter_drain(waiter) != 0) return -1;
    return drmSyncobjEventfd(
        waiter->drm_fd,
        waiter->handle,
        point,
        waiter->event_fd,
        0);
}

int nucleus_android_syncobj_waiter_notification_fd(
    nucleus_android_syncobj_waiter *waiter) {
    if (!waiter) {
        errno = EINVAL;
        return -1;
    }
    return waiter->event_fd;
}

int nucleus_android_syncobj_waiter_drain(
    nucleus_android_syncobj_waiter *waiter) {
    if (!waiter) {
        errno = EINVAL;
        return -1;
    }
    uint64_t value = 0;
    ssize_t result;
    do {
        result = read(waiter->event_fd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno == EAGAIN) return 0;
    return result == (ssize_t)sizeof(value) ? 0 : -1;
}

int nucleus_android_syncobj_timeline_export_sync_file(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point) {
    if (!timeline || point == 0) {
        errno = EINVAL;
        return -1;
    }
    uint32_t temporary = 0;
    if (drmSyncobjCreate(timeline->gpu->drm_fd, 0, &temporary) != 0) return -1;
    int result = drmSyncobjTransfer(
        timeline->gpu->drm_fd,
        temporary,
        0,
        timeline->handle,
        point,
        0);
    int fd = -1;
    if (result == 0) {
        result = drmSyncobjExportSyncFile(timeline->gpu->drm_fd, temporary, &fd);
    }
    (void)drmSyncobjDestroy(timeline->gpu->drm_fd, temporary);
    return result == 0 ? fd : -1;
}

int nucleus_android_syncobj_timeline_import_sync_file(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point,
    int sync_file) {
    if (!timeline || point == 0 || sync_file < 0) {
        errno = EINVAL;
        return -1;
    }
    uint32_t temporary = 0;
    if (drmSyncobjCreate(timeline->gpu->drm_fd, 0, &temporary) != 0) return -1;
    int result = drmSyncobjImportSyncFile(
        timeline->gpu->drm_fd, temporary, sync_file);
    if (result == 0) {
        result = drmSyncobjTransfer(
            timeline->gpu->drm_fd,
            timeline->handle,
            point,
            temporary,
            0,
            0);
    }
    (void)drmSyncobjDestroy(timeline->gpu->drm_fd, temporary);
    return result;
}

static VkClearColorValue nucleus_android_frame_color(uint64_t frame) {
    uint32_t phase = (uint32_t)(frame % 3);
    VkClearColorValue color = {.float32 = {0.04f, 0.04f, 0.04f, 1.0f}};
    color.float32[phase] = 0.85f;
    color.float32[(phase + 1) % 3] = 0.2f;
    return color;
}

int nucleus_android_gpu_buffer_render(
    nucleus_android_gpu_buffer *buffer,
    uint64_t frame_number,
    nucleus_android_syncobj_timeline *acquire_timeline,
    uint64_t acquire_point,
    nucleus_android_syncobj_timeline *release_timeline,
    uint64_t release_point,
    char *error_message,
    size_t error_capacity) {
    if (!buffer || !acquire_timeline || acquire_point == 0 ||
        acquire_timeline->gpu != buffer->gpu ||
        (release_timeline && release_timeline->gpu != buffer->gpu)) {
        errno = EINVAL;
        nucleus_android_error(error_message, error_capacity, "invalid render timeline contract");
        return -1;
    }
    nucleus_android_gpu *gpu = buffer->gpu;
    nucleus_android_collect_submissions(gpu);
    struct nucleus_android_submission *submission = calloc(1, sizeof(*submission));
    if (!submission) {
        nucleus_android_error(error_message, error_capacity, "out of memory");
        return -1;
    }

    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = gpu->queue_family};
    VkResult result = vkCreateCommandPool(
        gpu->device, &pool_info, NULL, &submission->command_pool);
    if (result != VK_SUCCESS) goto fail;
    VkCommandBufferAllocateInfo command_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = submission->command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1};
    VkCommandBuffer command = VK_NULL_HANDLE;
    result = vkAllocateCommandBuffers(gpu->device, &command_info, &command);
    if (result != VK_SUCCESS) goto fail;
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    result = vkBeginCommandBuffer(command, &begin);
    if (result != VK_SUCCESS) goto fail;

    VkImageMemoryBarrier to_transfer = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = buffer->layout == VK_IMAGE_LAYOUT_UNDEFINED
            ? 0
            : VK_ACCESS_MEMORY_READ_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = buffer->layout,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = buffer->image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1}};
    vkCmdPipelineBarrier(
        command,
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        NULL,
        0,
        NULL,
        1,
        &to_transfer);
    VkClearColorValue color = nucleus_android_frame_color(frame_number);
    VkImageSubresourceRange range = {
        .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1};
    vkCmdClearColorImage(
        command,
        buffer->image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &color,
        1,
        &range);
    VkImageMemoryBarrier to_general = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = buffer->image,
        .subresourceRange = range};
    vkCmdPipelineBarrier(
        command,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0,
        0,
        NULL,
        0,
        NULL,
        1,
        &to_general);
    result = vkEndCommandBuffer(command);
    if (result != VK_SUCCESS) goto fail;

    VkSemaphoreCreateInfo semaphore_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkSemaphore signal_semaphore = VK_NULL_HANDLE;
    VkExportSemaphoreCreateInfo export_info = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT};
    semaphore_info.pNext = &export_info;
    result = vkCreateSemaphore(
        gpu->device, &semaphore_info, NULL, &signal_semaphore);
    if (result != VK_SUCCESS) goto fail;

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSemaphore wait_semaphore = VK_NULL_HANDLE;
    if (release_timeline && release_point > 0) {
        int release_fd = nucleus_android_syncobj_timeline_export_sync_file(
            release_timeline, release_point);
        if (release_fd < 0) {
            vkDestroySemaphore(gpu->device, signal_semaphore, NULL);
            nucleus_android_error(
                error_message, error_capacity, "failed to materialize release timeline point");
            goto fail_without_result;
        }
        semaphore_info.pNext = NULL;
        result = vkCreateSemaphore(
            gpu->device, &semaphore_info, NULL, &wait_semaphore);
        if (result != VK_SUCCESS) {
            close(release_fd);
            vkDestroySemaphore(gpu->device, signal_semaphore, NULL);
            goto fail;
        }
        VkImportSemaphoreFdInfoKHR import = {
            .sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
            .semaphore = wait_semaphore,
            .flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            .fd = release_fd};
        result = gpu->import_semaphore_fd(gpu->device, &import);
        if (result != VK_SUCCESS) {
            close(release_fd);
            vkDestroySemaphore(gpu->device, wait_semaphore, NULL);
            vkDestroySemaphore(gpu->device, signal_semaphore, NULL);
            goto fail;
        }
    }

    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    result = vkCreateFence(gpu->device, &fence_info, NULL, &submission->fence);
    if (result != VK_SUCCESS) {
        if (wait_semaphore) vkDestroySemaphore(gpu->device, wait_semaphore, NULL);
        vkDestroySemaphore(gpu->device, signal_semaphore, NULL);
        goto fail;
    }
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = wait_semaphore ? 1u : 0u,
        .pWaitSemaphores = wait_semaphore ? &wait_semaphore : NULL,
        .pWaitDstStageMask = wait_semaphore ? &wait_stage : NULL,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphore};
    result = vkQueueSubmit(gpu->queue, 1, &submit, submission->fence);
    if (result != VK_SUCCESS) {
        vkDestroyFence(gpu->device, submission->fence, NULL);
        submission->fence = VK_NULL_HANDLE;
        if (wait_semaphore) vkDestroySemaphore(gpu->device, wait_semaphore, NULL);
        vkDestroySemaphore(gpu->device, signal_semaphore, NULL);
        goto fail;
    }

    VkSemaphoreGetFdInfoKHR get_fd = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
        .semaphore = signal_semaphore,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT};
    int acquire_fd = -1;
    result = gpu->get_semaphore_fd(gpu->device, &get_fd, &acquire_fd);
    if (result != VK_SUCCESS || acquire_fd < 0) {
        nucleus_android_vulkan_error(
            error_message, error_capacity, "vkGetSemaphoreFdKHR", result);
        submission->wait_semaphore = wait_semaphore;
        submission->signal_semaphore = signal_semaphore;
        submission->next = gpu->submissions;
        gpu->submissions = submission;
        return -1;
    }
    int import_result = nucleus_android_syncobj_timeline_import_sync_file(
        acquire_timeline, acquire_point, acquire_fd);
    close(acquire_fd);
    if (import_result != 0) {
        nucleus_android_error(
            error_message, error_capacity, "failed to import render fence into acquire timeline");
        submission->wait_semaphore = wait_semaphore;
        submission->signal_semaphore = signal_semaphore;
        submission->next = gpu->submissions;
        gpu->submissions = submission;
        return -1;
    }
    buffer->layout = VK_IMAGE_LAYOUT_GENERAL;
    submission->wait_semaphore = wait_semaphore;
    submission->signal_semaphore = signal_semaphore;
    submission->next = gpu->submissions;
    gpu->submissions = submission;
    return 0;

fail:
    nucleus_android_vulkan_error(error_message, error_capacity, "Vulkan render", result);
fail_without_result:
    if (submission->fence) vkDestroyFence(gpu->device, submission->fence, NULL);
    if (submission->command_pool) {
        vkDestroyCommandPool(gpu->device, submission->command_pool, NULL);
    }
    free(submission);
    return -1;
}

uint32_t nucleus_android_drm_format_xrgb8888(void) { return DRM_FORMAT_XRGB8888; }
uint32_t nucleus_android_drm_format_argb8888(void) { return DRM_FORMAT_ARGB8888; }
uint32_t nucleus_android_drm_format_xbgr8888(void) { return DRM_FORMAT_XBGR8888; }
uint32_t nucleus_android_drm_format_abgr8888(void) { return DRM_FORMAT_ABGR8888; }
uint64_t nucleus_android_drm_modifier_linear(void) { return DRM_FORMAT_MOD_LINEAR; }
