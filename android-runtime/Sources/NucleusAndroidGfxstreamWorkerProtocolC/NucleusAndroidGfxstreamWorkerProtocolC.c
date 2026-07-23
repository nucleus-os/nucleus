#include "NucleusAndroidGfxstreamWorkerProtocolC.h"

_Static_assert(
    NUCLEUS_ANDROID_GFXSTREAM_WORKER_DESCRIPTOR_COUNT ==
        NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT * 2 + 1,
    "worker descriptor roles must cover every buffer and the acquire timeline");
