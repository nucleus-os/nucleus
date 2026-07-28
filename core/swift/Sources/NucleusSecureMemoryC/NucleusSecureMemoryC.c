#include "NucleusSecureMemoryC.h"

void nucleus_secure_zero(void *bytes, size_t count) {
    volatile unsigned char *cursor = (volatile unsigned char *)bytes;
    while (count > 0) {
        *cursor = 0;
        ++cursor;
        --count;
    }
}
