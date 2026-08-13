#ifndef NUCLEUS_ANDROID_DRM_C_TEST_SUPPORT_H
#define NUCLEUS_ANDROID_DRM_C_TEST_SUPPORT_H

#include <NucleusAndroidDrmC.h>

#ifdef __cplusplus
extern "C" {
#endif

nucleus_android_gpu_lifetime_resource *
nucleus_android_test_lifetime_resource_create(
    nucleus_android_gpu_lifetime_domain *domain);

#ifdef __cplusplus
}
#endif

#endif
