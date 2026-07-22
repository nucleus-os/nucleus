#ifndef NUCLEUS_BENCHMARK_METRICS_C_H
#define NUCLEUS_BENCHMARK_METRICS_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct nucleus_benchmark_resource_snapshot {
    uint64_t heap_live_bytes;
    uint64_t allocator_mapped_bytes;
    uint64_t maximum_resident_bytes;
    uint64_t open_file_descriptors;
};

int nucleus_benchmark_capture_resources(
    struct nucleus_benchmark_resource_snapshot *snapshot);

#ifdef __cplusplus
}
#endif

#endif
