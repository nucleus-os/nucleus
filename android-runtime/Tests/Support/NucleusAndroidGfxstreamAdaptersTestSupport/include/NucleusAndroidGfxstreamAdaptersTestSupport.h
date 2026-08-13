#ifndef NUCLEUS_ANDROID_GFXSTREAM_ADAPTERS_TEST_SUPPORT_H
#define NUCLEUS_ANDROID_GFXSTREAM_ADAPTERS_TEST_SUPPORT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_android_test_result {
    const char *check_name;
    const char *source_file;
    int source_line;
    const char *diagnostic;
} nucleus_android_test_result;

nucleus_android_test_result nucleus_android_test_guest_ring_stream(void);
nucleus_android_test_result nucleus_android_test_guest_ring_factory_registration(void);
nucleus_android_test_result nucleus_android_test_host_ring_channel_pump(void);
nucleus_android_test_result nucleus_android_test_ring_peer_closure(void);

#ifdef __cplusplus
}
#endif

#endif
