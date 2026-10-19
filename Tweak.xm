#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <substrate.h>
#import <roothide.h>
#include <sys/socket.h>
#include <netdb.h>
#include <errno.h>

// These hooks only cover injected processes, not the device network stack.
static NSDictionary *ProxySettings(void) {
    NSString *path = jbroot(@"/Library/DomainProxy/proxy.pac");
    return @{
        @"ProxyAutoConfigEnable": @YES,
        @"ProxyAutoConfigURLString": [NSURL fileURLWithPath:path].absoluteString
    };
}

%hook NSURLSessionConfiguration
- (NSDictionary *)connectionProxyDictionary {
    return ProxySettings();
}
%end

static CFDictionaryRef (*OriginalProxySettings)(void);
static CFDictionaryRef ReplacedProxySettings(void) {
    return (__bridge_retained CFDictionaryRef)ProxySettings();
}

static int (*OriginalSocket)(int, int, int);
static int ReplacedSocket(int domain, int type, int protocol) {
    if (domain == AF_INET6) { errno = EAFNOSUPPORT; return -1; }
    return OriginalSocket(domain, type, protocol);
}

static int (*OriginalGetaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
static int ReplacedGetaddrinfo(const char *node, const char *service,
                              const struct addrinfo *hints, struct addrinfo **result) {
    if (hints && hints->ai_family == AF_INET6) {
        if (result) *result = NULL;
        return EAI_FAMILY;
    }
    struct addrinfo ipv4 = {};
    if (hints) ipv4 = *hints;
    if (ipv4.ai_family == AF_UNSPEC) ipv4.ai_family = AF_INET;
    return OriginalGetaddrinfo(node, service, &ipv4, result);
}

%ctor {
    @autoreleasepool {
        // Skip system UI; users should enable injection only for target apps.
        if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])
            return;
        %init;
        MSHookFunction((void *)&CFNetworkCopySystemProxySettings,
                       (void *)&ReplacedProxySettings, (void **)&OriginalProxySettings);
        MSHookFunction((void *)&socket, (void *)&ReplacedSocket, (void **)&OriginalSocket);
        MSHookFunction((void *)&getaddrinfo, (void *)&ReplacedGetaddrinfo,
                       (void **)&OriginalGetaddrinfo);
    }
}
