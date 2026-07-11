#ifndef CPEBBLEPLATFORM_H
#define CPEBBLEPLATFORM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PB_PLATFORM_ABI_VERSION 2u

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
    uint32_t has_native_audio;
    uint32_t reserved[7];
} PBPlatformCapabilities;

typedef struct PBSocket PBSocket;
typedef struct PBAudioDevice PBAudioDevice;
typedef void (*PBAudioRenderCallback)(float *interleaved_samples,
                                      uint32_t frame_count,
                                      uint32_t channel_count,
                                      void *user_data);

typedef enum PBSocketShutdown {
    PB_SOCKET_SHUTDOWN_READ = 0,
    PB_SOCKET_SHUTDOWN_WRITE = 1,
    PB_SOCKET_SHUTDOWN_BOTH = 2
} PBSocketShutdown;

uint32_t pb_platform_abi_version(void);
PBPlatformStatus pb_platform_get_capabilities(PBPlatformCapabilities *out_caps);
const char *pb_platform_last_error(void);
void pb_platform_clear_error(void);

PBPlatformStatus pb_socket_connect(const char *host, uint16_t port, PBSocket **out_socket);
PBPlatformStatus pb_socket_listen(uint16_t port, int32_t backlog, PBSocket **out_socket, uint16_t *out_bound_port);
PBPlatformStatus pb_socket_accept(PBSocket *listener, PBSocket **out_socket);
PBPlatformStatus pb_socket_send(PBSocket *socket, const uint8_t *bytes, size_t length, size_t *out_sent);
PBPlatformStatus pb_socket_receive(PBSocket *socket, uint8_t *bytes, size_t capacity, size_t *out_received);
PBPlatformStatus pb_socket_shutdown(PBSocket *socket, PBSocketShutdown direction);
void pb_socket_interrupt(PBSocket *socket);
void pb_socket_close(PBSocket *socket);

PBPlatformStatus pb_audio_create(uint32_t sample_rate, uint32_t channels,
                                 uint32_t period_frames,
                                 PBAudioRenderCallback callback, void *user_data,
                                 PBAudioDevice **out_device);
PBPlatformStatus pb_audio_start(PBAudioDevice *device);
PBPlatformStatus pb_audio_stop(PBAudioDevice *device);
uint64_t pb_audio_underrun_count(PBAudioDevice *device);
void pb_audio_destroy(PBAudioDevice *device);

#ifdef __cplusplus
}
#endif

#endif /* CPEBBLEPLATFORM_H */
