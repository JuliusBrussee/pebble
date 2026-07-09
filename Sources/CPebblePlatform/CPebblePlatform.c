#include "CPebblePlatform.h"

#include <stddef.h>
#include <string.h>

#if defined(_MSC_VER)
#define PB_THREAD_LOCAL __declspec(thread)
#else
#define PB_THREAD_LOCAL _Thread_local
#endif

static PB_THREAD_LOCAL char pb_last_error[256];

static PBPlatformStatus pb_set_error(PBPlatformStatus status, const char *message) {
    if (message == NULL) {
        pb_last_error[0] = '\0';
    } else {
        strncpy(pb_last_error, message, sizeof(pb_last_error) - 1);
        pb_last_error[sizeof(pb_last_error) - 1] = '\0';
    }
    return status;
}

uint32_t pb_platform_abi_version(void) {
    return PB_PLATFORM_ABI_VERSION;
}

PBPlatformStatus pb_platform_get_capabilities(PBPlatformCapabilities *out_caps) {
    if (out_caps == NULL) {
        return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "PBPlatformCapabilities pointer is null");
    }
    if (out_caps->struct_size < sizeof(PBPlatformCapabilities)) {
        return pb_set_error(PB_PLATFORM_BAD_SIZE, "PBPlatformCapabilities struct_size is too small");
    }

    memset(out_caps, 0, sizeof(PBPlatformCapabilities));
    out_caps->struct_size = (uint32_t)sizeof(PBPlatformCapabilities);
    out_caps->abi_version = PB_PLATFORM_ABI_VERSION;
    return pb_set_error(PB_PLATFORM_OK, NULL);
}

const char *pb_platform_last_error(void) {
    return pb_last_error;
}

void pb_platform_clear_error(void) {
    pb_last_error[0] = '\0';
}
