#include "NucleusAndroidDrmCTestSupport.h"

void nucleus_android_gpu_testing_force_fences_pending(
    nucleus_android_gpu *gpu,
    int enabled);
void nucleus_android_gpu_testing_fail_next_post_submit(
    nucleus_android_gpu *gpu);
uint64_t nucleus_android_gpu_buffer_testing_last_use_serial(
    nucleus_android_gpu_buffer *buffer);
int nucleus_android_gpu_buffer_testing_has_general_layout(
    nucleus_android_gpu_buffer *buffer);
nucleus_android_gpu *nucleus_android_gpu_testing_lifetime_domain_create(void);
void nucleus_android_gpu_testing_lifetime_domain_destroy(
    nucleus_android_gpu *gpu);
nucleus_android_gpu_buffer *
nucleus_android_gpu_buffer_testing_lifetime_domain_create(
    nucleus_android_gpu *gpu);
uint64_t nucleus_android_gpu_buffer_testing_record_submission(
    nucleus_android_gpu_buffer *buffer);
void nucleus_android_gpu_testing_complete_through(
    nucleus_android_gpu *gpu,
    uint64_t serial);

void nucleus_android_test_gpu_force_fences_pending(
    nucleus_android_gpu *gpu,
    int enabled) {
    nucleus_android_gpu_testing_force_fences_pending(gpu, enabled);
}

void nucleus_android_test_gpu_fail_next_post_submit(
    nucleus_android_gpu *gpu) {
    nucleus_android_gpu_testing_fail_next_post_submit(gpu);
}

uint64_t nucleus_android_test_gpu_buffer_last_use_serial(
    nucleus_android_gpu_buffer *buffer) {
    return nucleus_android_gpu_buffer_testing_last_use_serial(buffer);
}

int nucleus_android_test_gpu_buffer_has_general_layout(
    nucleus_android_gpu_buffer *buffer) {
    return nucleus_android_gpu_buffer_testing_has_general_layout(buffer);
}

nucleus_android_gpu *nucleus_android_test_gpu_lifetime_domain_create(void) {
    return nucleus_android_gpu_testing_lifetime_domain_create();
}

void nucleus_android_test_gpu_lifetime_domain_destroy(
    nucleus_android_gpu *gpu) {
    nucleus_android_gpu_testing_lifetime_domain_destroy(gpu);
}

nucleus_android_gpu_buffer *
nucleus_android_test_gpu_buffer_lifetime_domain_create(
    nucleus_android_gpu *gpu) {
    return nucleus_android_gpu_buffer_testing_lifetime_domain_create(gpu);
}

uint64_t nucleus_android_test_gpu_buffer_record_submission(
    nucleus_android_gpu_buffer *buffer) {
    return nucleus_android_gpu_buffer_testing_record_submission(buffer);
}

void nucleus_android_test_gpu_complete_through(
    nucleus_android_gpu *gpu,
    uint64_t serial) {
    nucleus_android_gpu_testing_complete_through(gpu, serial);
}
