#ifndef NUCLEUS_ANDROID_GFXSTREAM_SOCKET_TRANSPORT_H
#define NUCLEUS_ANDROID_GFXSTREAM_SOCKET_TRANSPORT_H

#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_android_gfxstream_install_socket_transport(
    nucleus_android_gfxstream_set_external_iostream_factory setter,
    const char *socket_path);

#ifdef __cplusplus
}
#endif

#endif
