#ifndef NUCLEUS_ANDROID_GPU_LIFETIME_C_H
#define NUCLEUS_ANDROID_GPU_LIFETIME_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_android_gpu_lifetime_domain
    nucleus_android_gpu_lifetime_domain;
typedef struct nucleus_android_gpu_lifetime_resource
    nucleus_android_gpu_lifetime_resource;
typedef void (*nucleus_android_gpu_lifetime_reclaim)(void *context);

struct nucleus_android_gpu_lifetime_snapshot {
    uint64_t live_resource_count;
    uint64_t retired_resource_count;
    uint64_t reclaimed_resource_count;
    uint64_t submitted_serial;
    uint64_t completed_serial;
    int32_t terminal_submission_result;
};

nucleus_android_gpu_lifetime_domain *
nucleus_android_gpu_lifetime_domain_create(void);
void nucleus_android_gpu_lifetime_domain_destroy(
    nucleus_android_gpu_lifetime_domain *domain);

nucleus_android_gpu_lifetime_resource *
nucleus_android_gpu_lifetime_resource_create(
    nucleus_android_gpu_lifetime_domain *domain,
    void *context,
    nucleus_android_gpu_lifetime_reclaim reclaim);
void nucleus_android_gpu_lifetime_resource_retire(
    nucleus_android_gpu_lifetime_resource *resource);

int nucleus_android_gpu_lifetime_domain_has_submission_capacity(
    nucleus_android_gpu_lifetime_domain *domain);
uint64_t nucleus_android_gpu_lifetime_record_submission(
    nucleus_android_gpu_lifetime_resource *resource);

void nucleus_android_gpu_lifetime_domain_complete_through(
    nucleus_android_gpu_lifetime_domain *domain,
    uint64_t serial,
    int32_t terminal_submission_result);
void nucleus_android_gpu_lifetime_domain_get_snapshot(
    nucleus_android_gpu_lifetime_domain *domain,
    struct nucleus_android_gpu_lifetime_snapshot *output);

#ifdef __cplusplus
}
#endif

#endif
