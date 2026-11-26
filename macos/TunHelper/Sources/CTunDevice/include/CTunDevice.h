#ifndef V2RAYM_TUN_DEVICE_H
#define V2RAYM_TUN_DEVICE_H
#include <net/if.h>
#include <stdbool.h>
#include <stdint.h>

// A successful call gives the caller an owned descriptor and the kernel-assigned interface name.
int v2m_open_tunnel(char name[IFNAMSIZ], int mtu, const char *gateway, int prefix,
                    const char *local6, int prefix6);
// Returns an errno value. The target interface is derived from the helper's own open descriptor.
int v2m_open_route_writer(int tunnel_fd, uint16_t *index);
int v2m_change_route(int socket_fd, uint16_t index, bool add, const char *destination, int prefix, const char *gateway);
#endif
