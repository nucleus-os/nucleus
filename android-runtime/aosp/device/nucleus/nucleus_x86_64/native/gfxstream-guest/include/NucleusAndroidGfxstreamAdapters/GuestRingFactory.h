#ifndef NUCLEUS_ANDROID_GFXSTREAM_GUEST_RING_FACTORY_H
#define NUCLEUS_ANDROID_GFXSTREAM_GUEST_RING_FACTORY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_android_gfxstream_endpoint_descriptors {
    int command_memory_fd;
    int command_data_notification_fd;
    int command_space_notification_fd;
    int response_memory_fd;
    int response_data_notification_fd;
    int response_space_notification_fd;
} nucleus_android_gfxstream_endpoint_descriptors;

typedef int (*nucleus_android_gfxstream_endpoint_provider)(
    void *context,
    nucleus_android_gfxstream_endpoint_descriptors *descriptors);

typedef void *(*nucleus_android_gfxstream_external_iostream_factory)(
    void *context,
    size_t buffer_size);

typedef void (*nucleus_android_gfxstream_set_external_iostream_factory)(
    nucleus_android_gfxstream_external_iostream_factory factory,
    void *context);

typedef struct nucleus_android_gfxstream_factory_registration
    nucleus_android_gfxstream_factory_registration;

nucleus_android_gfxstream_factory_registration *
nucleus_android_gfxstream_factory_registration_create(
    void *gfxstream_icd_handle,
    nucleus_android_gfxstream_endpoint_provider provider,
    void *provider_context);

nucleus_android_gfxstream_factory_registration *
nucleus_android_gfxstream_factory_registration_create_with_setter(
    nucleus_android_gfxstream_set_external_iostream_factory setter,
    nucleus_android_gfxstream_endpoint_provider provider,
    void *provider_context);

void nucleus_android_gfxstream_factory_registration_destroy(
    nucleus_android_gfxstream_factory_registration *registration);

#ifdef __cplusplus
}
#endif

#endif
