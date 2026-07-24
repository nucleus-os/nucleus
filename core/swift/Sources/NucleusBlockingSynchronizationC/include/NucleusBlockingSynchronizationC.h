#ifndef NUCLEUS_BLOCKING_SYNCHRONIZATION_C_H
#define NUCLEUS_BLOCKING_SYNCHRONIZATION_C_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nucleus_blocking_synchronization
    nucleus_blocking_synchronization;

nucleus_blocking_synchronization *
nucleus_blocking_synchronization_create(void);

int nucleus_blocking_synchronization_lock(
    nucleus_blocking_synchronization *synchronization);
int nucleus_blocking_synchronization_wait(
    nucleus_blocking_synchronization *synchronization);
int nucleus_blocking_synchronization_signal(
    nucleus_blocking_synchronization *synchronization);
int nucleus_blocking_synchronization_broadcast(
    nucleus_blocking_synchronization *synchronization);
int nucleus_blocking_synchronization_unlock(
    nucleus_blocking_synchronization *synchronization);

void nucleus_blocking_synchronization_destroy(
    nucleus_blocking_synchronization *synchronization);

#ifdef __cplusplus
}
#endif

#endif
