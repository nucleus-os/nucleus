#ifndef NUCLEUS_ANDROID_GFXSTREAM_ADAPTERS_TEST_SUPPORT_H
#define NUCLEUS_ANDROID_GFXSTREAM_ADAPTERS_TEST_SUPPORT_H

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_android_test_guest_ring_stream(void);
int nucleus_android_test_guest_ring_factory_registration(void);
int nucleus_android_test_host_ring_channel_pump(void);
int nucleus_android_test_ring_peer_closure(void);

#ifdef __cplusplus
}
#endif

#endif
