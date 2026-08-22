#include "NucleusAndroidPresentationProtocol.h"

_Static_assert(
    sizeof(struct nucleus_android_presentation_message_header) == 12,
    "presentation header ABI changed");
_Static_assert(
    sizeof(struct nucleus_android_presentation_frame) <=
        NUCLEUS_ANDROID_PRESENTATION_MAX_MESSAGE_BYTES,
    "presentation frame exceeds protocol bound");
_Static_assert(
    sizeof(struct nucleus_android_presentation_frame_reply) <=
        NUCLEUS_ANDROID_PRESENTATION_MAX_MESSAGE_BYTES,
    "presentation reply exceeds protocol bound");
