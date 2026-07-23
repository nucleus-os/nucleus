#ifndef NUCLEUS_ANDROID_GFXSTREAM_HOST_C_H
#define NUCLEUS_ANDROID_GFXSTREAM_HOST_C_H

#include <stddef.h>
#include <stdint.h>

#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_android_gfxstream_host_renderer
    nucleus_android_gfxstream_host_renderer;
typedef struct nucleus_android_gfxstream_host_connection
    nucleus_android_gfxstream_host_connection;

typedef int (*nucleus_android_gfxstream_host_export_release_sync_file)(
    void *context,
    uint32_t color_buffer_handle);
typedef int (*nucleus_android_gfxstream_host_import_acquire_sync_file)(
    void *context,
    uint32_t color_buffer_handle,
    int sync_file);

typedef struct nucleus_android_gfxstream_host_dmabuf {
    uint32_t color_buffer_handle;
    uint32_t width;
    uint32_t height;
    uint32_t drm_format;
    uint64_t drm_modifier;
    uint32_t plane_offset;
    uint32_t plane_stride;
    int dmabuf_fd;
    void *sync_context;
    nucleus_android_gfxstream_host_export_release_sync_file
        export_release_sync_file;
    nucleus_android_gfxstream_host_import_acquire_sync_file
        import_acquire_sync_file;
} nucleus_android_gfxstream_host_dmabuf;

typedef enum nucleus_android_gfxstream_host_pump_result {
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_IDLE = 0,
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS = 1,
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_WAITING_FOR_RESPONSE_SPACE = 2,
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_WAITING_FOR_RENDER_CHANNEL = 3,
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_STOPPED = 4,
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_ERROR = 5,
    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PEER_CLOSED = 6,
} nucleus_android_gfxstream_host_pump_result;

nucleus_android_gfxstream_host_renderer *
nucleus_android_gfxstream_host_renderer_create(
    uint32_t width,
    uint32_t height,
    const char *vulkan_device_uuid,
    char *error_message,
    size_t error_capacity);
void nucleus_android_gfxstream_host_renderer_destroy(
    nucleus_android_gfxstream_host_renderer *renderer);

/* Ownership of dmabuf_fd transfers on success and remains with the caller on
 * failure. */
int nucleus_android_gfxstream_host_import_dmabuf(
    nucleus_android_gfxstream_host_renderer *renderer,
    const nucleus_android_gfxstream_host_dmabuf *dmabuf);
int nucleus_android_gfxstream_host_release_dmabuf(
    nucleus_android_gfxstream_host_renderer *renderer,
    uint32_t color_buffer_handle);

/* Takes ownership of all six endpoint descriptors on success and failure. */
nucleus_android_gfxstream_host_connection *
nucleus_android_gfxstream_host_connection_create(
    nucleus_android_gfxstream_host_renderer *renderer,
    struct nucleus_android_gfxstream_endpoint_descriptors descriptors,
    uint32_t context_id);
void nucleus_android_gfxstream_host_connection_destroy(
    nucleus_android_gfxstream_host_connection *connection);
nucleus_android_gfxstream_host_pump_result
nucleus_android_gfxstream_host_connection_pump(
    nucleus_android_gfxstream_host_connection *connection);
int nucleus_android_gfxstream_host_connection_command_notification_fd(
    nucleus_android_gfxstream_host_connection *connection);
int nucleus_android_gfxstream_host_connection_response_space_notification_fd(
    nucleus_android_gfxstream_host_connection *connection);
int nucleus_android_gfxstream_host_connection_renderer_notification_fd(
    nucleus_android_gfxstream_host_connection *connection);
int nucleus_android_gfxstream_host_connection_drain_renderer_notification(
    nucleus_android_gfxstream_host_connection *connection);

#ifdef __cplusplus
}
#endif

#endif
