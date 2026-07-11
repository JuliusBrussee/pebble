#include "CPebblePlatform.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET pb_native_socket;
typedef int pb_socklen;
#define PB_INVALID_SOCKET INVALID_SOCKET
#define pb_native_close closesocket
#else
#include <errno.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
typedef int pb_native_socket;
typedef socklen_t pb_socklen;
#define PB_INVALID_SOCKET (-1)
#define pb_native_close close
#endif

#if defined(_MSC_VER)
#define PB_THREAD_LOCAL __declspec(thread)
#else
#define PB_THREAD_LOCAL _Thread_local
#endif

static PB_THREAD_LOCAL char pb_last_error[256];

struct PBSocket {
    pb_native_socket fd;
};

static PBPlatformStatus pb_set_error(PBPlatformStatus status, const char *message) {
    if (message == NULL) {
        pb_last_error[0] = '\0';
    } else {
        strncpy(pb_last_error, message, sizeof(pb_last_error) - 1);
        pb_last_error[sizeof(pb_last_error) - 1] = '\0';
    }
    return status;
}

static PBPlatformStatus pb_socket_error(const char *operation) {
#if defined(_WIN32)
    snprintf(pb_last_error, sizeof(pb_last_error), "%s failed: WSA error %d", operation, WSAGetLastError());
#else
    snprintf(pb_last_error, sizeof(pb_last_error), "%s failed: %s", operation, strerror(errno));
#endif
    return PB_PLATFORM_INTERNAL;
}

static int pb_socket_runtime_init(void) {
#if defined(_WIN32)
    static int initialized = 0;
    if (!initialized) {
        WSADATA data;
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return 0;
        initialized = 1;
    }
#endif
    return 1;
}

static PBSocket *pb_socket_wrap(pb_native_socket fd) {
    PBSocket *socket = (PBSocket *)malloc(sizeof(PBSocket));
    if (socket == NULL) {
        pb_native_close(fd);
        pb_set_error(PB_PLATFORM_INTERNAL, "socket handle allocation failed");
        return NULL;
    }
    socket->fd = fd;
    return socket;
}

static void pb_socket_configure(pb_native_socket fd) {
#if defined(__APPLE__)
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#else
    (void)fd;
#endif
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
    out_caps->has_sockets = 1;
#if defined(__APPLE__) || defined(_WIN32)
    out_caps->has_native_audio = 1;
#endif
    return pb_set_error(PB_PLATFORM_OK, NULL);
}

const char *pb_platform_last_error(void) {
    return pb_last_error;
}

void pb_platform_clear_error(void) {
    pb_last_error[0] = '\0';
}

PBPlatformStatus pb_socket_connect(const char *host, uint16_t port, PBSocket **out_socket) {
    if (host == NULL || host[0] == '\0' || port == 0 || out_socket == NULL) {
        return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "connect requires host, nonzero port, and output socket");
    }
    *out_socket = NULL;
    if (!pb_socket_runtime_init()) return pb_socket_error("socket runtime initialization");

    char service[6];
    snprintf(service, sizeof(service), "%u", (unsigned)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *addresses = NULL;
    int lookup = getaddrinfo(host, service, &hints, &addresses);
    if (lookup != 0) {
        snprintf(pb_last_error, sizeof(pb_last_error), "address lookup failed: %d", lookup);
        return PB_PLATFORM_UNAVAILABLE;
    }

    pb_native_socket connected = PB_INVALID_SOCKET;
    for (struct addrinfo *it = addresses; it != NULL; it = it->ai_next) {
        pb_native_socket fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd == PB_INVALID_SOCKET) continue;
        pb_socket_configure(fd);
        if (connect(fd, it->ai_addr, (pb_socklen)it->ai_addrlen) == 0) {
            connected = fd;
            break;
        }
        pb_native_close(fd);
    }
    freeaddrinfo(addresses);
    if (connected == PB_INVALID_SOCKET) return pb_socket_error("connect");
    *out_socket = pb_socket_wrap(connected);
    return *out_socket == NULL ? PB_PLATFORM_INTERNAL : pb_set_error(PB_PLATFORM_OK, NULL);
}

PBPlatformStatus pb_socket_listen(uint16_t port, int32_t backlog, PBSocket **out_socket, uint16_t *out_bound_port) {
    if (out_socket == NULL || out_bound_port == NULL || backlog < 1) {
        return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "listen requires output pointers and positive backlog");
    }
    *out_socket = NULL;
    *out_bound_port = 0;
    if (!pb_socket_runtime_init()) return pb_socket_error("socket runtime initialization");

    pb_native_socket fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    int family = AF_INET6;
    if (fd == PB_INVALID_SOCKET) {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        family = AF_INET;
    }
    if (fd == PB_INVALID_SOCKET) return pb_socket_error("socket");
    pb_socket_configure(fd);
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));
    if (family == AF_INET6) {
        int dualStack = 0;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&dualStack, sizeof(dualStack));
        struct sockaddr_in6 address;
        memset(&address, 0, sizeof(address));
        address.sin6_family = AF_INET6;
        address.sin6_addr = in6addr_any;
        address.sin6_port = htons(port);
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            pb_native_close(fd);
            return pb_socket_error("bind");
        }
    } else {
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons(port);
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            pb_native_close(fd);
            return pb_socket_error("bind");
        }
    }
    if (listen(fd, backlog) != 0) {
        pb_native_close(fd);
        return pb_socket_error("listen");
    }
    struct sockaddr_storage bound;
    pb_socklen boundLength = (pb_socklen)sizeof(bound);
    if (getsockname(fd, (struct sockaddr *)&bound, &boundLength) != 0) {
        pb_native_close(fd);
        return pb_socket_error("getsockname");
    }
    *out_bound_port = ntohs(bound.ss_family == AF_INET6
        ? ((struct sockaddr_in6 *)&bound)->sin6_port
        : ((struct sockaddr_in *)&bound)->sin_port);
    *out_socket = pb_socket_wrap(fd);
    return *out_socket == NULL ? PB_PLATFORM_INTERNAL : pb_set_error(PB_PLATFORM_OK, NULL);
}

PBPlatformStatus pb_socket_accept(PBSocket *listener, PBSocket **out_socket) {
    if (listener == NULL || out_socket == NULL) return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "accept requires listener and output socket");
    *out_socket = NULL;
    pb_native_socket fd = accept(listener->fd, NULL, NULL);
    if (fd == PB_INVALID_SOCKET) return pb_socket_error("accept");
    pb_socket_configure(fd);
    *out_socket = pb_socket_wrap(fd);
    return *out_socket == NULL ? PB_PLATFORM_INTERNAL : pb_set_error(PB_PLATFORM_OK, NULL);
}

PBPlatformStatus pb_socket_send(PBSocket *socket, const uint8_t *bytes, size_t length, size_t *out_sent) {
    if (socket == NULL || (bytes == NULL && length != 0) || out_sent == NULL) return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "send arguments invalid");
#if defined(_WIN32)
    int result = send(socket->fd, (const char *)bytes, (int)length, 0);
#else
    ssize_t result = send(socket->fd, bytes, length, 0);
#endif
    if (result < 0) return pb_socket_error("send");
    *out_sent = (size_t)result;
    return pb_set_error(PB_PLATFORM_OK, NULL);
}

PBPlatformStatus pb_socket_receive(PBSocket *socket, uint8_t *bytes, size_t capacity, size_t *out_received) {
    if (socket == NULL || bytes == NULL || capacity == 0 || out_received == NULL) return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "receive arguments invalid");
#if defined(_WIN32)
    int result = recv(socket->fd, (char *)bytes, (int)capacity, 0);
#else
    ssize_t result = recv(socket->fd, bytes, capacity, 0);
#endif
    if (result < 0) return pb_socket_error("receive");
    *out_received = (size_t)result;
    return pb_set_error(PB_PLATFORM_OK, NULL);
}

PBPlatformStatus pb_socket_shutdown(PBSocket *socket, PBSocketShutdown direction) {
    if (socket == NULL) return pb_set_error(PB_PLATFORM_BAD_ARGUMENT, "shutdown requires socket");
#if defined(_WIN32)
    int how = direction == PB_SOCKET_SHUTDOWN_READ ? SD_RECEIVE : direction == PB_SOCKET_SHUTDOWN_WRITE ? SD_SEND : SD_BOTH;
#else
    int how = direction == PB_SOCKET_SHUTDOWN_READ ? SHUT_RD : direction == PB_SOCKET_SHUTDOWN_WRITE ? SHUT_WR : SHUT_RDWR;
#endif
    if (shutdown(socket->fd, how) != 0) return pb_socket_error("shutdown");
    return pb_set_error(PB_PLATFORM_OK, NULL);
}

void pb_socket_close(PBSocket *socket) {
    if (socket == NULL) return;
    pb_socket_interrupt(socket);
    free(socket);
}

void pb_socket_interrupt(PBSocket *socket) {
    if (socket == NULL) return;
    if (socket->fd != PB_INVALID_SOCKET) {
        pb_native_close(socket->fd);
        socket->fd = PB_INVALID_SOCKET;
    }
}
