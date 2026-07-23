#ifndef NUCLEUS_ANDROID_GFXSTREAM_WORKER_PROTOCOL_C_H
#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_PROTOCOL_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION 1
#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT 3
#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_DESCRIPTOR_COUNT 7
#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_PATH_CAPACITY 256
#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_UUID_CAPACITY 33
#define NUCLEUS_ANDROID_GFXSTREAM_WORKER_ERROR_CAPACITY 256

typedef enum nucleus_android_gfxstream_worker_message_type {
    NUCLEUS_ANDROID_GFXSTREAM_WORKER_INITIALIZE = 1,
    NUCLEUS_ANDROID_GFXSTREAM_WORKER_SUBMIT = 2,
    NUCLEUS_ANDROID_GFXSTREAM_WORKER_SHUTDOWN = 3,
    NUCLEUS_ANDROID_GFXSTREAM_WORKER_RESPONSE = 4,
} nucleus_android_gfxstream_worker_message_type;

typedef struct nucleus_android_gfxstream_worker_buffer {
    uint32_t color_buffer_handle;
    uint32_t plane_offset;
    uint32_t plane_stride;
    uint32_t reserved;
} nucleus_android_gfxstream_worker_buffer;

/*
 * Initialization carries seven SCM_RIGHTS descriptors in this order:
 * three dma-buf planes, one shared acquire timeline, and three per-buffer
 * release timelines.
 */
typedef struct nucleus_android_gfxstream_worker_initialize {
    uint32_t version;
    uint32_t type;
    uint32_t byte_count;
    uint32_t buffer_count;
    uint32_t width;
    uint32_t height;
    uint32_t drm_format;
    uint32_t reserved;
    uint64_t drm_modifier;
    char render_node[NUCLEUS_ANDROID_GFXSTREAM_WORKER_PATH_CAPACITY];
    char device_uuid[NUCLEUS_ANDROID_GFXSTREAM_WORKER_UUID_CAPACITY];
    nucleus_android_gfxstream_worker_buffer
        buffers[NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT];
} nucleus_android_gfxstream_worker_initialize;

typedef struct nucleus_android_gfxstream_worker_submit {
    uint32_t version;
    uint32_t type;
    uint32_t byte_count;
    uint32_t color_buffer_handle;
    uint64_t frame_number;
    uint64_t acquire_point;
    uint64_t release_point;
    uint32_t has_release_point;
    uint32_t reserved;
} nucleus_android_gfxstream_worker_submit;

typedef struct nucleus_android_gfxstream_worker_shutdown {
    uint32_t version;
    uint32_t type;
    uint32_t byte_count;
    uint32_t reserved;
} nucleus_android_gfxstream_worker_shutdown;

typedef struct nucleus_android_gfxstream_worker_response {
    uint32_t version;
    uint32_t type;
    uint32_t byte_count;
    int32_t status;
    uint64_t frame_number;
    char error[NUCLEUS_ANDROID_GFXSTREAM_WORKER_ERROR_CAPACITY];
} nucleus_android_gfxstream_worker_response;

#ifdef __cplusplus
}
#endif

#endif
