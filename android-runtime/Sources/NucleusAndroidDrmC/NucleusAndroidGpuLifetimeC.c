#include "NucleusAndroidGpuLifetimeC.h"

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

struct nucleus_android_gpu_lifetime_resource {
    nucleus_android_gpu_lifetime_domain *domain;
    void *context;
    nucleus_android_gpu_lifetime_reclaim reclaim;
    uint64_t last_use_serial;
    struct nucleus_android_gpu_lifetime_resource *retired_next;
};

struct nucleus_android_gpu_lifetime_domain {
    pthread_mutex_t mutex;
    struct nucleus_android_gpu_lifetime_resource *retired_resources;
    uint64_t next_submission_serial;
    struct nucleus_android_gpu_lifetime_snapshot snapshot;
};

static void nucleus_android_gpu_lifetime_reclaim_resources(
    nucleus_android_gpu_lifetime_resource *resources) {
    while (resources) {
        nucleus_android_gpu_lifetime_resource *resource = resources;
        resources = resource->retired_next;
        resource->reclaim(resource->context);
        free(resource);
    }
}

nucleus_android_gpu_lifetime_domain *
nucleus_android_gpu_lifetime_domain_create(void) {
    nucleus_android_gpu_lifetime_domain *domain = calloc(1, sizeof(*domain));
    if (!domain) return NULL;
    int result = pthread_mutex_init(&domain->mutex, NULL);
    if (result != 0) {
        errno = result;
        free(domain);
        return NULL;
    }
    domain->next_submission_serial = 1;
    return domain;
}

void nucleus_android_gpu_lifetime_domain_destroy(
    nucleus_android_gpu_lifetime_domain *domain) {
    if (!domain) return;
    (void)pthread_mutex_lock(&domain->mutex);
    nucleus_android_gpu_lifetime_resource *retired =
        domain->retired_resources;
    domain->retired_resources = NULL;
    domain->snapshot.live_resource_count -=
        domain->snapshot.retired_resource_count;
    domain->snapshot.reclaimed_resource_count +=
        domain->snapshot.retired_resource_count;
    domain->snapshot.retired_resource_count = 0;
    (void)pthread_mutex_unlock(&domain->mutex);
    nucleus_android_gpu_lifetime_reclaim_resources(retired);
    (void)pthread_mutex_destroy(&domain->mutex);
    free(domain);
}

nucleus_android_gpu_lifetime_resource *
nucleus_android_gpu_lifetime_resource_create(
    nucleus_android_gpu_lifetime_domain *domain,
    void *context,
    nucleus_android_gpu_lifetime_reclaim reclaim) {
    if (!domain || !reclaim) {
        errno = EINVAL;
        return NULL;
    }
    nucleus_android_gpu_lifetime_resource *resource =
        calloc(1, sizeof(*resource));
    if (!resource) return NULL;
    resource->domain = domain;
    resource->context = context;
    resource->reclaim = reclaim;
    (void)pthread_mutex_lock(&domain->mutex);
    ++domain->snapshot.live_resource_count;
    (void)pthread_mutex_unlock(&domain->mutex);
    return resource;
}

void nucleus_android_gpu_lifetime_resource_retire(
    nucleus_android_gpu_lifetime_resource *resource) {
    if (!resource) return;
    nucleus_android_gpu_lifetime_domain *domain = resource->domain;
    bool reclaim = false;
    (void)pthread_mutex_lock(&domain->mutex);
    if (resource->last_use_serial <= domain->snapshot.completed_serial) {
        --domain->snapshot.live_resource_count;
        ++domain->snapshot.reclaimed_resource_count;
        reclaim = true;
    } else {
        resource->retired_next = domain->retired_resources;
        domain->retired_resources = resource;
        ++domain->snapshot.retired_resource_count;
    }
    (void)pthread_mutex_unlock(&domain->mutex);
    if (reclaim) {
        resource->reclaim(resource->context);
        free(resource);
    }
}

int nucleus_android_gpu_lifetime_domain_has_submission_capacity(
    nucleus_android_gpu_lifetime_domain *domain) {
    if (!domain) return 0;
    (void)pthread_mutex_lock(&domain->mutex);
    int result = domain->next_submission_serial != UINT64_MAX;
    (void)pthread_mutex_unlock(&domain->mutex);
    return result;
}

uint64_t nucleus_android_gpu_lifetime_record_submission(
    nucleus_android_gpu_lifetime_resource *resource) {
    if (!resource) {
        errno = EINVAL;
        return 0;
    }
    nucleus_android_gpu_lifetime_domain *domain = resource->domain;
    (void)pthread_mutex_lock(&domain->mutex);
    if (domain->next_submission_serial == UINT64_MAX) {
        (void)pthread_mutex_unlock(&domain->mutex);
        errno = EOVERFLOW;
        return 0;
    }
    uint64_t serial = domain->next_submission_serial++;
    resource->last_use_serial = serial;
    domain->snapshot.submitted_serial = serial;
    (void)pthread_mutex_unlock(&domain->mutex);
    return serial;
}

void nucleus_android_gpu_lifetime_domain_complete_through(
    nucleus_android_gpu_lifetime_domain *domain,
    uint64_t serial,
    int32_t terminal_submission_result) {
    if (!domain) return;
    nucleus_android_gpu_lifetime_resource *reclaimed = NULL;
    (void)pthread_mutex_lock(&domain->mutex);
    if (serial > domain->snapshot.completed_serial) {
        domain->snapshot.completed_serial = serial;
    }
    if (terminal_submission_result != 0 &&
        domain->snapshot.terminal_submission_result == 0) {
        domain->snapshot.terminal_submission_result =
            terminal_submission_result;
    }
    nucleus_android_gpu_lifetime_resource **link =
        &domain->retired_resources;
    while (*link) {
        nucleus_android_gpu_lifetime_resource *resource = *link;
        if (resource->last_use_serial > domain->snapshot.completed_serial) {
            link = &resource->retired_next;
            continue;
        }
        *link = resource->retired_next;
        resource->retired_next = reclaimed;
        reclaimed = resource;
        --domain->snapshot.live_resource_count;
        --domain->snapshot.retired_resource_count;
        ++domain->snapshot.reclaimed_resource_count;
    }
    (void)pthread_mutex_unlock(&domain->mutex);
    nucleus_android_gpu_lifetime_reclaim_resources(reclaimed);
}

void nucleus_android_gpu_lifetime_domain_get_snapshot(
    nucleus_android_gpu_lifetime_domain *domain,
    struct nucleus_android_gpu_lifetime_snapshot *output) {
    if (!domain || !output) return;
    (void)pthread_mutex_lock(&domain->mutex);
    *output = domain->snapshot;
    (void)pthread_mutex_unlock(&domain->mutex);
}
