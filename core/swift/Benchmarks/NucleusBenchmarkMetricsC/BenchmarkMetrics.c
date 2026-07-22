#define _GNU_SOURCE
#include "NucleusBenchmarkMetricsC.h"

#include <dirent.h>
#include <limits.h>
#include <malloc.h>
#include <stddef.h>
#include <string.h>
#include <sys/resource.h>

static uint64_t saturating_add_size(size_t lhs, size_t rhs) {
    if (lhs > UINT64_MAX - rhs) return UINT64_MAX;
    return (uint64_t)lhs + (uint64_t)rhs;
}

static int count_open_file_descriptors(uint64_t *count) {
    DIR *directory = opendir("/proc/self/fd");
    if (directory == NULL) return -1;
    uint64_t result = 0;
    for (;;) {
        struct dirent *entry = readdir(directory);
        if (entry == NULL) break;
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (result != UINT64_MAX) ++result;
    }
    if (closedir(directory) != 0) return -1;
    // opendir itself contributed one descriptor while the directory was read.
    if (result > 0) --result;
    *count = result;
    return 0;
}

int nucleus_benchmark_capture_resources(
    struct nucleus_benchmark_resource_snapshot *snapshot) {
    if (snapshot == NULL) return -1;
    memset(snapshot, 0, sizeof(*snapshot));
    if (count_open_file_descriptors(&snapshot->open_file_descriptors) != 0) {
        return -1;
    }

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0 || usage.ru_maxrss < 0) return -1;
    uint64_t maximum_resident_kib = (uint64_t)usage.ru_maxrss;
    snapshot->maximum_resident_bytes =
        maximum_resident_kib > UINT64_MAX / 1024
            ? UINT64_MAX
            : maximum_resident_kib * 1024;

    struct mallinfo2 allocator = mallinfo2();
    snapshot->heap_live_bytes = (uint64_t)allocator.uordblks;
    snapshot->allocator_mapped_bytes = saturating_add_size(
        allocator.arena, allocator.hblkhd);
    return 0;
}
