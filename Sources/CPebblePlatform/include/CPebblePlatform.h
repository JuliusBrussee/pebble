#ifndef CPEBBLEPLATFORM_H
#define CPEBBLEPLATFORM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PB_PLATFORM_ABI_VERSION 1u

typedef enum PBPlatformStatus {
    PB_PLATFORM_OK = 0,
    PB_PLATFORM_BAD_ARGUMENT = -1,
    PB_PLATFORM_BAD_SIZE = -2,
    PB_PLATFORM_UNAVAILABLE = -3,
    PB_PLATFORM_INTERNAL = -4
} PBPlatformStatus;

typedef struct PBPlatformCapabilities {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t has_vulkan;
    uint32_t has_sdl;
    uint32_t has_miniaudio;
    uint32_t has_sockets;
    uint32_t has_codecs;
    uint32_t reserved[8];
} PBPlatformCapabilities;

uint32_t pb_platform_abi_version(void);
PBPlatformStatus pb_platform_get_capabilities(PBPlatformCapabilities *out_caps);
const char *pb_platform_last_error(void);
void pb_platform_clear_error(void);

#ifdef __cplusplus
}
#endif

#endif /* CPEBBLEPLATFORM_H */
