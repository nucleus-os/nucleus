#ifndef NUCLEUS_ANDROID_GFXSTREAM_SOCKET_TRANSPORT_H
#define NUCLEUS_ANDROID_GFXSTREAM_SOCKET_TRANSPORT_H

#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_android_gfxstream_install_socket_transport(
    nucleus_android_gfxstream_set_external_iostream_factory setter,
    nucleus_android_gfxstream_set_external_memory_mapper memory_setter,
    nucleus_android_gfxstream_set_external_vulkan_fence_exporter
        fence_exporter_setter,
    nucleus_android_gfxstream_set_external_vulkan_semaphore_exporter
        semaphore_exporter_setter,
    nucleus_android_gfxstream_set_external_vulkan_qsri_exporter
        qsri_exporter_setter,
    const char *socket_path);

#ifdef __cplusplus
}
#endif

#endif
