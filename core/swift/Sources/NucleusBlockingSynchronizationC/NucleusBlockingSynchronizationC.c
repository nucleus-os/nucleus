#include "NucleusBlockingSynchronizationC.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>

struct nucleus_blocking_synchronization {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
};

nucleus_blocking_synchronization *
nucleus_blocking_synchronization_create(void) {
    nucleus_blocking_synchronization *synchronization =
        calloc(1, sizeof(*synchronization));
    if (synchronization == NULL) {
        return NULL;
    }

    int result = pthread_mutex_init(&synchronization->mutex, NULL);
    if (result != 0) {
        errno = result;
        free(synchronization);
        return NULL;
    }

    result = pthread_cond_init(&synchronization->condition, NULL);
    if (result != 0) {
        errno = result;
        (void)pthread_mutex_destroy(&synchronization->mutex);
        free(synchronization);
        return NULL;
    }

    return synchronization;
}

int nucleus_blocking_synchronization_lock(
    nucleus_blocking_synchronization *synchronization
) {
    if (synchronization == NULL) {
        return EINVAL;
    }
    return pthread_mutex_lock(&synchronization->mutex);
}

int nucleus_blocking_synchronization_wait(
    nucleus_blocking_synchronization *synchronization
) {
    if (synchronization == NULL) {
        return EINVAL;
    }
    return pthread_cond_wait(
        &synchronization->condition,
        &synchronization->mutex);
}

int nucleus_blocking_synchronization_signal(
    nucleus_blocking_synchronization *synchronization
) {
    if (synchronization == NULL) {
        return EINVAL;
    }
    return pthread_cond_signal(&synchronization->condition);
}

int nucleus_blocking_synchronization_broadcast(
    nucleus_blocking_synchronization *synchronization
) {
    if (synchronization == NULL) {
        return EINVAL;
    }
    return pthread_cond_broadcast(&synchronization->condition);
}

int nucleus_blocking_synchronization_unlock(
    nucleus_blocking_synchronization *synchronization
) {
    if (synchronization == NULL) {
        return EINVAL;
    }
    return pthread_mutex_unlock(&synchronization->mutex);
}

void nucleus_blocking_synchronization_destroy(
    nucleus_blocking_synchronization *synchronization
) {
    if (synchronization == NULL) {
        return;
    }
    (void)pthread_cond_destroy(&synchronization->condition);
    (void)pthread_mutex_destroy(&synchronization->mutex);
    free(synchronization);
}
