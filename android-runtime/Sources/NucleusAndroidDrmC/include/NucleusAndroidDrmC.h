#ifndef NUCLEUS_ANDROID_DRM_C_H
#define NUCLEUS_ANDROID_DRM_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NUCLEUS_ANDROID_DRM_PATH_MAX 256
#define NUCLEUS_ANDROID_GPU_NAME_MAX 256
#define NUCLEUS_ANDROID_GPU_UUID_HEX_MAX 33
#define NUCLEUS_ANDROID_GPU_MAX_PLANES 4

struct nucleus_android_device_id {
    uint32_t major;
    uint32_t minor;
};

struct nucleus_android_drm_candidate {
    char render_path[NUCLEUS_ANDROID_DRM_PATH_MAX];
    char primary_path[NUCLEUS_ANDROID_DRM_PATH_MAX];
    struct nucleus_android_device_id render_device;
    struct nucleus_android_device_id primary_device;
    uint16_t pci_domain;
    uint8_t pci_bus;
    uint8_t pci_device;
    uint8_t pci_function;
    uint16_t vendor_id;
    uint16_t product_id;
};

struct nucleus_android_gpu_diagnostic {
    char device_name[NUCLEUS_ANDROID_GPU_NAME_MAX];
    char driver_name[NUCLEUS_ANDROID_GPU_NAME_MAX];
    char driver_info[NUCLEUS_ANDROID_GPU_NAME_MAX];
    char gbm_backend[NUCLEUS_ANDROID_GPU_NAME_MAX];
    char device_uuid[NUCLEUS_ANDROID_GPU_UUID_HEX_MAX];
    uint32_t api_version;
    uint32_t driver_id;
    uint32_t device_type;
    uint8_t hardware_driver;
};

struct nucleus_android_dmabuf_plane {
    uint32_t offset;
    uint32_t stride;
};

struct nucleus_android_format_modifier_properties {
    uint64_t modifier;
    uint64_t features;
    uint32_t plane_count;
};

typedef struct nucleus_android_gpu nucleus_android_gpu;
typedef struct nucleus_android_gpu_buffer nucleus_android_gpu_buffer;
typedef struct nucleus_android_syncobj_timeline nucleus_android_syncobj_timeline;
typedef struct nucleus_android_syncobj_waiter nucleus_android_syncobj_waiter;

int nucleus_android_drm_enumerate(
    struct nucleus_android_drm_candidate *output,
    size_t capacity);
int nucleus_android_drm_device_id(
    const char *path,
    struct nucleus_android_device_id *output);
int nucleus_android_drm_device_id_from_native(
    const void *bytes,
    size_t byte_count,
    struct nucleus_android_device_id *output);

nucleus_android_gpu *nucleus_android_gpu_create(
    const char *render_path,
    char *error_message,
    size_t error_capacity);
void nucleus_android_gpu_destroy(nucleus_android_gpu *gpu);
int nucleus_android_gpu_get_diagnostic(
    nucleus_android_gpu *gpu,
    struct nucleus_android_gpu_diagnostic *output);
int nucleus_android_gpu_supports_format_modifier(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    uint64_t modifier);
int nucleus_android_gpu_format_modifier_properties(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    uint64_t modifier,
    uint32_t *output_plane_count,
    uint64_t *output_features);
int nucleus_android_gpu_list_format_modifiers(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    struct nucleus_android_format_modifier_properties *output,
    size_t capacity);
int nucleus_android_gpu_preferred_modifier(
    nucleus_android_gpu *gpu,
    uint32_t drm_format,
    uint64_t *output_modifier);

nucleus_android_gpu_buffer *nucleus_android_gpu_buffer_create(
    nucleus_android_gpu *gpu,
    uint32_t width,
    uint32_t height,
    uint32_t drm_format,
    uint64_t modifier,
    int scanout,
    char *error_message,
    size_t error_capacity);
void nucleus_android_gpu_buffer_destroy(nucleus_android_gpu_buffer *buffer);
uint32_t nucleus_android_gpu_buffer_plane_count(nucleus_android_gpu_buffer *buffer);
int nucleus_android_gpu_buffer_export_plane(
    nucleus_android_gpu_buffer *buffer,
    uint32_t plane_index,
    struct nucleus_android_dmabuf_plane *output_layout);
int nucleus_android_gpu_buffer_render(
    nucleus_android_gpu_buffer *buffer,
    uint64_t frame_number,
    nucleus_android_syncobj_timeline *acquire_timeline,
    uint64_t acquire_point,
    nucleus_android_syncobj_timeline *release_timeline,
    uint64_t release_point,
    char *error_message,
    size_t error_capacity);

nucleus_android_syncobj_timeline *nucleus_android_syncobj_timeline_create(
    nucleus_android_gpu *gpu);
nucleus_android_syncobj_timeline *nucleus_android_syncobj_timeline_import_fd(
    nucleus_android_gpu *gpu,
    int timeline_fd);
void nucleus_android_syncobj_timeline_destroy(
    nucleus_android_syncobj_timeline *timeline);
int nucleus_android_syncobj_timeline_export_fd(
    nucleus_android_syncobj_timeline *timeline);
int nucleus_android_syncobj_timeline_signal(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point);
int nucleus_android_syncobj_timeline_is_signaled(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point);
int nucleus_android_syncobj_timeline_export_sync_file(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point);
int nucleus_android_syncobj_timeline_import_sync_file(
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point,
    int sync_file);

nucleus_android_syncobj_waiter *nucleus_android_syncobj_waiter_create(
    const char *render_path,
    int timeline_fd);
void nucleus_android_syncobj_waiter_destroy(nucleus_android_syncobj_waiter *waiter);
int nucleus_android_syncobj_waiter_is_signaled(
    nucleus_android_syncobj_waiter *waiter,
    uint64_t point);
int nucleus_android_syncobj_waiter_arm(
    nucleus_android_syncobj_waiter *waiter,
    uint64_t point);
int nucleus_android_syncobj_waiter_notification_fd(
    nucleus_android_syncobj_waiter *waiter);
int nucleus_android_syncobj_waiter_drain(
    nucleus_android_syncobj_waiter *waiter);

uint32_t nucleus_android_drm_format_xrgb8888(void);
uint32_t nucleus_android_drm_format_argb8888(void);
uint32_t nucleus_android_drm_format_xbgr8888(void);
uint32_t nucleus_android_drm_format_abgr8888(void);
uint64_t nucleus_android_drm_modifier_linear(void);

#ifdef __cplusplus
}
#endif

#endif
