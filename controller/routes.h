#include <sys/sysctl.h>
#include <net/route.h>

// Preserve physical-interface reachability while global utun routes are active.
static NSArray<NSData *> *RouteSnapshot(void) {
    int mib[] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0};
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0)) return nil;
    NSMutableData *buffer = [NSMutableData dataWithLength:length];
    if (sysctl(mib, 6, buffer.mutableBytes, &length, NULL, 0)) return nil;
    NSMutableArray *result = [NSMutableArray new];
    for (size_t offset = 0; offset + sizeof(struct rt_msghdr) <= length;) {
        struct rt_msghdr *r = (struct rt_msghdr *)((char *)buffer.mutableBytes + offset);
        if (r->rtm_msglen < sizeof(*r) || offset + r->rtm_msglen > length) break;
        [result addObject:[NSData dataWithBytes:r length:r->rtm_msglen]];
        offset += r->rtm_msglen;
    }
    return result;
}
static int ChangeRoute(NSData *wire, int operation) {
    NSMutableData *request = [wire mutableCopy];
    struct rt_msghdr *r = (struct rt_msghdr *)request.mutableBytes;
    r->rtm_type = operation; r->rtm_pid = getpid(); r->rtm_seq = 9173; r->rtm_errno = 0;
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return errno;
    struct timeval timeout = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int result = 0;
    if (write(fd, request.bytes, request.length) != (ssize_t)request.length) result = errno ?: EIO;
    else {
        char reply[16384]; ssize_t size;
        result = ETIMEDOUT;
        while ((size = read(fd, reply, sizeof(reply))) >= (ssize_t)sizeof(struct rt_msghdr)) {
            struct rt_msghdr *answer = (struct rt_msghdr *)reply;
            if (answer->rtm_pid == getpid() && answer->rtm_seq == 9173) { result = answer->rtm_errno; break; }
        }
    }
    close(fd); return result;
}
static BOOL RestoreScopedRoutes(void) {
    NSArray *saved = [NSArray arrayWithContentsOfFile:Path(@"scoped-routes.plist")];
    BOOL ok = YES;
    for (NSData *wire in saved) {
        int code = ChangeRoute(wire, RTM_DELETE);
        if (code && code != ESRCH) ok = NO;
    }
    if (ok) unlink(Path(@"scoped-routes.plist").fileSystemRepresentation);
    return ok;
}
static BOOL PrepareScopedRoutes(void) {
    NSArray *snapshot = RouteSnapshot();
    if (!snapshot) return NO;
    NSMutableArray *added = [NSMutableArray new];
    for (NSData *wire in snapshot) {
        struct rt_msghdr *r = (struct rt_msghdr *)wire.bytes;
        if (!(r->rtm_flags & RTF_GATEWAY) || (r->rtm_flags & RTF_IFSCOPE)) continue;
        const char *cursor = (const char *)wire.bytes + sizeof(*r), *end = (const char *)wire.bytes + wire.length;
        const struct sockaddr_in *destination = NULL;
        BOOL maskIsZero = YES;
        for (int slot = 0; slot < RTAX_MAX && cursor + 2 <= end; slot++) {
            if (!(r->rtm_addrs & (1 << slot))) continue;
            const struct sockaddr *a = (const struct sockaddr *)cursor;
            size_t step = a->sa_len ? (a->sa_len + 3) & ~3 : 4;
            if (cursor + step > end) { destination = NULL; break; }
            if (slot == RTAX_DST && a->sa_family == AF_INET && a->sa_len >= sizeof(struct sockaddr_in)) destination = (const struct sockaddr_in *)a;
            if (slot == RTAX_NETMASK) for (int i = 2; i < a->sa_len; i++) if (cursor[i]) maskIsZero = NO;
            cursor += step;
        }
        if (!destination || destination->sin_addr.s_addr || !maskIsZero) continue;
        NSMutableData *scoped = [wire mutableCopy];
        ((struct rt_msghdr *)scoped.mutableBytes)->rtm_flags |= RTF_IFSCOPE;
        int code = ChangeRoute(scoped, RTM_ADD);
        if (!code) {
            [added addObject:scoped];
            if (![added writeToFile:Path(@"scoped-routes.plist") atomically:YES]) {
                for (NSData *created in added) ChangeRoute(created, RTM_DELETE);
                return NO;
            }
        } else if (code != EEXIST) {
            RestoreScopedRoutes(); return NO;
        }
    }
    return YES;
}
