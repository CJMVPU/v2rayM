#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/sockio.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <net/if_dl.h>
#include <net/if_utun.h>
#include <net/route.h>
#include <netinet6/in6_var.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include "CTunDevice.h"

static struct sockaddr_in ipv4(uint32_t host) {
    struct sockaddr_in result = {.sin_len = sizeof(result), .sin_family = AF_INET};
    result.sin_addr.s_addr = htonl(host);
    return result;
}

static int interface_name(int fd, char name[IFNAMSIZ]) {
    socklen_t length = IFNAMSIZ;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &length) < 0) return errno;
    if (length > IFNAMSIZ || !memchr(name, 0, length) || strncmp(name, "utun", 4)) return EINVAL;
    return 0;
}

static int configure(const char *name, int mtu, uint32_t gateway, uint32_t mask, const struct in6_addr *local6, int prefix6) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return errno;
    struct ifreq request = {0};
    strlcpy(request.ifr_name, name, sizeof(request.ifr_name));
    request.ifr_mtu = mtu;
    struct ifaliasreq addr = {0};
    strlcpy(addr.ifra_name, name, sizeof(addr.ifra_name));
    struct sockaddr_in local = ipv4(gateway + 1), remote = ipv4(gateway), netmask = ipv4(mask);
    memcpy(&addr.ifra_addr, &local, sizeof(local));
    memcpy(&addr.ifra_broadaddr, &remote, sizeof(remote));
    memcpy(&addr.ifra_mask, &netmask, sizeof(netmask));
    int error = 0;
    if (ioctl(fd, SIOCSIFMTU, &request) < 0 || ioctl(fd, SIOCAIFADDR, &addr) < 0) error = errno;
    close(fd);
    if (error) return error;

    fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd < 0) return errno;
    struct in6_aliasreq link = {0};
    strlcpy(link.ifra_name, name, sizeof(link.ifra_name));
    link.ifra_addr.sin6_len = link.ifra_prefixmask.sin6_len = sizeof(struct sockaddr_in6);
    link.ifra_addr.sin6_family = link.ifra_prefixmask.sin6_family = AF_INET6;
    link.ifra_addr.sin6_addr.s6_addr[0] = 0xfe;
    link.ifra_addr.sin6_addr.s6_addr[1] = 0x80;
    memcpy(link.ifra_addr.sin6_addr.s6_addr + 12, &local.sin_addr, 4);
    memset(link.ifra_prefixmask.sin6_addr.s6_addr, 0xff, 8);
    link.ifra_flags = IN6_IFF_NODAD;
    link.ifra_lifetime.ia6t_pltime = link.ifra_lifetime.ia6t_vltime = UINT32_MAX;
    if (ioctl(fd, SIOCAIFADDR_IN6, &link) < 0) error = errno;
    if (!error && local6) {
        link.ifra_addr.sin6_addr = *local6;
        memset(&link.ifra_prefixmask.sin6_addr, 0, sizeof(link.ifra_prefixmask.sin6_addr));
        for (int bit = 0; bit < prefix6; bit++)
            link.ifra_prefixmask.sin6_addr.s6_addr[bit / 8] |= 0x80 >> (bit % 8);
        if (ioctl(fd, SIOCAIFADDR_IN6, &link) < 0) error = errno;
    }
    close(fd);
    return error;
}

int v2m_open_tunnel(char name[IFNAMSIZ], int mtu, const char *gateway, int prefix,
                    const char *local6, int prefix6) {
    struct in6_addr ipv6;
    if (local6 && (prefix6 < 1 || prefix6 > 127 || inet_pton(AF_INET6, local6, &ipv6) != 1)) {
        errno = EINVAL; return -1;
    }
    struct in_addr v4;
    if (mtu < 1280 || mtu > 65535 || prefix < 1 || prefix > 31 || inet_pton(AF_INET, gateway, &v4) != 1) {
        errno = EINVAL; return -1;
    }
    uint32_t address = ntohl(v4.s_addr), mask = UINT32_MAX << (32 - prefix);
    if (!address || address >> 24 == 127 || address >> 28 >= 14 || ((address + 1) & mask) != (address & mask)) {
        errno = EINVAL; return -1;
    }
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    struct sockaddr_ctl control = {.sc_len = sizeof(control), .sc_family = AF_SYSTEM, .ss_sysaddr = AF_SYS_CONTROL};
    int error = 0;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || ioctl(fd, CTLIOCGINFO, &info) < 0) error = errno;
    if (!error) {
        control.sc_id = info.ctl_id;
        if (connect(fd, (struct sockaddr *)&control, sizeof(control)) < 0) error = errno;
    }
    if (!error) error = interface_name(fd, name);
    if (!error) error = configure(name, mtu, address, mask, local6 ? &ipv6 : NULL, prefix6);
    if (error) { close(fd); errno = error; return -1; }
    return fd;
}

struct route_packet {
    struct rt_msghdr header;
    unsigned char addresses[3 * sizeof(struct sockaddr_storage)];
};

static void append_address(struct route_packet *p, const struct sockaddr *address) {
    memcpy((char *)p + p->header.rtm_msglen, address, address->sa_len);
    p->header.rtm_msglen += (address->sa_len + 3) & ~3;
}

int v2m_open_route_writer(int fd, uint16_t *index_out) {
    char name[IFNAMSIZ] = {0};
    int error = interface_name(fd, name);
    if (error) { errno = error; return -1; }
    unsigned int index = if_nametoindex(name);
    if (!index || index > UINT16_MAX) { errno = ENXIO; return -1; }
    int sock = socket(PF_ROUTE, SOCK_RAW, 0);
    if (sock < 0) return -1;
    int disable = 0;
    if (fcntl(sock, F_SETFD, FD_CLOEXEC) < 0 ||
        setsockopt(sock, SOL_SOCKET, SO_USELOOPBACK, &disable, sizeof(disable)) < 0) {
        error = errno; close(sock); errno = error; return -1;
    }
    *index_out = (uint16_t)index;
    return sock;
}

int v2m_change_route(int sock, uint16_t index, bool add, const char *destination, int prefix, const char *gateway) {
    struct route_packet packet = {0};
    packet.header.rtm_msglen = sizeof(packet.header);
    packet.header.rtm_version = RTM_VERSION;
    packet.header.rtm_type = add ? RTM_ADD : RTM_DELETE;
    packet.header.rtm_flags = RTF_STATIC | (add ? RTF_UP : 0);
    packet.header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    packet.header.rtm_seq = 1;
    struct sockaddr_in dst = ipv4(0), remote = ipv4(0);
    struct sockaddr_in6 dst6 = {.sin6_len = sizeof(dst6), .sin6_family = AF_INET6};
    if (inet_pton(AF_INET, destination, &dst.sin_addr) == 1) {
        if (prefix < 1 || prefix > 32 || inet_pton(AF_INET, gateway, &remote.sin_addr) != 1) return EINVAL;
        struct sockaddr_in mask = ipv4(UINT32_MAX << (32 - prefix));
        packet.header.rtm_flags |= RTF_GATEWAY;
        append_address(&packet, (struct sockaddr *)&dst);
        append_address(&packet, (struct sockaddr *)&remote);
        append_address(&packet, (struct sockaddr *)&mask);
    } else {
        if (prefix < 1 || prefix > 128 || inet_pton(AF_INET6, destination, &dst6.sin6_addr) != 1) return EINVAL;
        struct sockaddr_dl link = {.sdl_len = sizeof(link), .sdl_family = AF_LINK, .sdl_index = index};
        struct sockaddr_in6 mask = {.sin6_len = sizeof(mask), .sin6_family = AF_INET6};
        for (int bit = 0; bit < prefix; bit++) mask.sin6_addr.s6_addr[bit / 8] |= 0x80 >> (bit % 8);
        packet.header.rtm_index = index;
        append_address(&packet, (struct sockaddr *)&dst6);
        append_address(&packet, (struct sockaddr *)&link);
        append_address(&packet, (struct sockaddr *)&mask);
    }
    ssize_t count = write(sock, &packet, packet.header.rtm_msglen);
    if (count < 0) return errno;
    return count == packet.header.rtm_msglen ? 0 : EIO;
}
