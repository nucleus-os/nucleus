#ifndef NUCLEUS_ANDROID_DRM_C_TEST_SUPPORT_H
#define NUCLEUS_ANDROID_DRM_C_TEST_SUPPORT_H

#include <stdint.h>
#include "NucleusAndroidDrmC.h"

#ifdef __cplusplus
extern "C" {
#endif

void nucleus_android_test_gpu_force_fences_pending(
    nucleus_android_gpu *gpu,
    int enabled);
void nucleus_android_test_gpu_fail_next_post_submit(
    nucleus_android_gpu *gpu);
uint64_t nucleus_android_test_gpu_buffer_last_use_serial(
    nucleus_android_gpu_buffer *buffer);
int nucleus_android_test_gpu_buffer_has_general_layout(
    nucleus_android_gpu_buffer *buffer);
nucleus_android_gpu *nucleus_android_test_gpu_lifetime_domain_create(void);
void nucleus_android_test_gpu_lifetime_domain_destroy(
    nucleus_android_gpu *gpu);
nucleus_android_gpu_buffer *
nucleus_android_test_gpu_buffer_lifetime_domain_create(
    nucleus_android_gpu *gpu);
uint64_t nucleus_android_test_gpu_buffer_record_submission(
    nucleus_android_gpu_buffer *buffer);
void nucleus_android_test_gpu_complete_through(
    nucleus_android_gpu *gpu,
    uint64_t serial);

#ifdef __cplusplus
}
#endif

#endif
