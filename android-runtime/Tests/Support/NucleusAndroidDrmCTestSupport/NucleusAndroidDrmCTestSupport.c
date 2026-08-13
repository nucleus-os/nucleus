#include "NucleusAndroidDrmCTestSupport.h"

#include <stdlib.h>

static void nucleus_android_test_lifetime_resource_reclaim(void *context) {
    free(context);
}

nucleus_android_gpu_lifetime_resource *
nucleus_android_test_lifetime_resource_create(
    nucleus_android_gpu_lifetime_domain *domain) {
    void *context = malloc(1);
    if (!context) return NULL;
    nucleus_android_gpu_lifetime_resource *resource =
        nucleus_android_gpu_lifetime_resource_create(
            domain,
            context,
            nucleus_android_test_lifetime_resource_reclaim);
    if (!resource) free(context);
    return resource;
}
