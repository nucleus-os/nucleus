#include "NucleusAndroidDisplayControlProtocol.h"

_Static_assert(
    sizeof(struct nucleus_android_display_control_header) == 12,
    "display-control header ABI changed");
_Static_assert(
    sizeof(struct nucleus_android_display_control_register) <=
        NUCLEUS_ANDROID_DISPLAY_CONTROL_MAX_MESSAGE_BYTES,
    "display-control registration exceeds packet bound");
_Static_assert(
    sizeof(struct nucleus_android_display_control_configuration) <=
        NUCLEUS_ANDROID_DISPLAY_CONTROL_MAX_MESSAGE_BYTES,
    "display-control configuration exceeds packet bound");
