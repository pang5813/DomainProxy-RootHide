#import <Foundation/Foundation.h>
#import <roothide.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <spawn.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
extern char **environ;
extern "C" int proc_pidpath(int, void *, uint32_t);
extern "C" int memorystatus_control(uint32_t, int32_t, uint32_t, void *, size_t);

static BOOL SetCoreMemoryBudget(pid_t pid) {
    // XNU MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT / GET_MEMLIMIT_PROPERTIES.
    // RootHide's launchd proxy can ignore plist JetsamProperties; verify the kernel value.
    struct { int32_t active; uint32_t activeFlags; int32_t inactive; uint32_t inactiveFlags; } limits = {};
    if (memorystatus_control(6, pid, 256, NULL, 0) != 0) return NO;
    return memorystatus_control(8, pid, 0, &limits, sizeof(limits)) == 0 && limits.active >= 256 && limits.inactive >= 256;
}

static NSString *StateDirectory(void) { return jbroot(@"/var/run/domainproxy"); }
static NSString *CorePath(void) { return jbroot(@"/usr/libexec/domainproxy-core"); }
static void Reply(NSDictionary *value, int code) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    exit(code);
}
static void Fail(NSString *message) { Reply(@{@"ok": @NO, @"message": message}, 1); }
static NSString *Path(NSString *name) { return [StateDirectory() stringByAppendingPathComponent:name]; }
static NSString *ServiceTarget(void) { return @"system/local.domainproxy.tunnel"; }
static NSDictionary *Launchctl(NSArray<NSString *> *arguments) {
    NSString *tool = jbroot(@"/bin/launchctl");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:tool]) tool = @"/bin/launchctl";
    NSArray<NSString *> *all = [@[tool] arrayByAddingObjectsFromArray:arguments];
    char **args = (char **)calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; ++i) args[i] = strdup(all[i].UTF8String);
    int pipes[2];
    NSMutableData *output = [NSMutableData new];
    int code = pipe(pipes), status = 0;
    if (code == 0) {
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, pipes[0]);
        posix_spawn_file_actions_addclose(&actions, pipes[1]);
        char *env[] = {(char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin", (char *)"HOME=/var/root", NULL};
        pid_t child = 0;
        code = posix_spawn(&child, tool.fileSystemRepresentation, &actions, NULL, args, env);
        posix_spawn_file_actions_destroy(&actions);
        close(pipes[1]);
        if (!code) {
            char buffer[2048]; ssize_t size;
            while ((size = read(pipes[0], buffer, sizeof(buffer))) > 0) [output appendBytes:buffer length:size];
            waitpid(child, &status, 0);
            code = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
        }
        close(pipes[0]);
    } else code = errno;
    for (NSUInteger i = 0; i < all.count; ++i) free(args[i]);
    free(args);
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
    return @{@"code": @(code), @"output": text};
}
static pid_t ServicePID(void) {
    NSDictionary *reply = Launchctl(@[@"print", ServiceTarget()]);
    if ([reply[@"code"] intValue]) return 0;
    NSString *text = reply[@"output"];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*pid = ([0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [[text substringWithRange:[match rangeAtIndex:1]] intValue] : 0;
}
static void AppendLog(NSString *text) {
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:Path(@"service.log")];
    if (!file) return;
    [file seekToEndOfFile];
    [file writeData:[[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}
static BOOL TunCounters(uint64_t *received, uint64_t *sent) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *it = interfaces; it; it = it->ifa_next) {
        if (strcmp(it->ifa_name, "utun99") || !it->ifa_addr || it->ifa_addr->sa_family != AF_LINK || !it->ifa_data) continue;
        struct if_data *data = (struct if_data *)it->ifa_data;
        *received = data->ifi_ibytes; *sent = data->ifi_obytes;
        found = YES; break;
    }
    freeifaddrs(interfaces);
    return found;
}
static BOOL ForwardingProbe(NSString **diagnostic) {
    uint64_t rxBefore = 0, txBefore = 0, rxAfter = 0, txAfter = 0;
    BOOL before = TunCounters(&rxBefore, &txBefore);
    // Query a non-proxied domain through the exact DNS server configured in the tunnel.
    const unsigned char query[] = {0x44,0x70,1,0,0,1,0,0,0,0,0,0,7,'e','x','a','m','p','l','e',3,'c','o','m',0,0,1,0,1};
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    BOOL answered = NO;
    if (fd >= 0) {
        struct timeval timeout = {4, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        struct sockaddr_in dns = {};
        dns.sin_len = sizeof(dns); dns.sin_family = AF_INET; dns.sin_port = htons(53);
        inet_pton(AF_INET, "223.5.5.5", &dns.sin_addr);
        if (connect(fd, (struct sockaddr *)&dns, sizeof(dns)) == 0 && send(fd, query, sizeof(query), 0) == (ssize_t)sizeof(query)) {
            unsigned char reply[2048];
            ssize_t size = recv(fd, reply, sizeof(reply), 0);
            answered = size >= 12 && reply[0] == 0x44 && reply[1] == 0x70 && (reply[2] & 0x80) && !(reply[3] & 0x0f) && (reply[6] || reply[7]);
        }
        close(fd);
    }
    BOOL after = TunCounters(&rxAfter, &txAfter);
    BOOL traffic = before && after && rxAfter > rxBefore && txAfter > txBefore;
    *diagnostic = [NSString stringWithFormat:@"启动自检：DNS=%@，utun99 接收 %llu→%llu，发送 %llu→%llu。", answered ? @"成功" : @"失败", (unsigned long long)rxBefore, (unsigned long long)rxAfter, (unsigned long long)txBefore, (unsigned long long)txAfter];
    return answered && traffic;
}
static pid_t RunningPID(void) {
    pid_t pid = [[NSString stringWithContentsOfFile:Path(@"pid") encoding:NSUTF8StringEncoding error:nil] intValue];
    if (pid <= 1 || kill(pid, 0) != 0) return 0;
    char actual[4096] = {}, expected[4096] = {}, resolved[4096] = {};
    if (proc_pidpath(pid, actual, sizeof(actual)) <= 0) return 0;
    if (!realpath(CorePath().fileSystemRepresentation, expected)) return 0;
    if (!realpath(actual, resolved)) return 0;
    return strcmp(expected, resolved) == 0 ? pid : 0;
}
#include "routes.h"
static NSDictionary *ControlRequest(NSString *method, NSDictionary *body) {
    NSString *secret = [NSString stringWithContentsOfFile:Path(@"api-token") encoding:NSUTF8StringEncoding error:nil];
    if (secret.length < 32) Fail(@"没有 API 密钥，请先启动新版服务。");
    NSData *json = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : [NSData data];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) Fail(@"无法创建本机 API 连接。");
    struct timeval timeout = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in address = {};
    address.sin_len = sizeof(address); address.sin_family = AF_INET; address.sin_port = htons(9099);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) { close(fd); Fail(@"切换 API 未运行，请先启动新版全局服务。"); }
    NSString *header = [NSString stringWithFormat:@"%@ /v1/proxy HTTP/1.1\r\nHost: 127.0.0.1:9099\r\nAuthorization: Bearer %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", method, secret, (unsigned long)json.length];
    NSMutableData *request = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [request appendData:json];
    NSUInteger offset = 0;
    while (offset < request.length) {
        ssize_t sent = send(fd, (const char *)request.bytes + offset, request.length - offset, 0);
        if (sent <= 0) { close(fd); Fail(@"发送切换请求失败。"); }
        offset += sent;
    }
    NSMutableData *response = [NSMutableData data];
    char buffer[2048]; ssize_t count;
    while ((count = recv(fd, buffer, sizeof(buffer), 0)) > 0 && response.length < 32768) [response appendBytes:buffer length:count];
    close(fd);
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange range = [response rangeOfData:separator options:0 range:NSMakeRange(0, response.length)];
    if (count < 0 || range.location == NSNotFound) Fail(@"切换 API 响应超时或无效，请刷新状态确认结果。");
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:[response subdataWithRange:NSMakeRange(NSMaxRange(range), response.length - NSMaxRange(range))] options:0 error:nil];
    if (![reply isKindOfClass:NSDictionary.class]) Fail(@"切换 API 返回无效数据。");
    return reply;
}
static NSDictionary *ProxyOptions(int argc, char **argv, BOOL jsonInput) {
    NSDictionary *input = nil;
    if (jsonInput) {
        NSMutableData *data = [NSMutableData data];
        char buffer[1024]; ssize_t count;
        while (data.length <= 8192 && (count = read(STDIN_FILENO, buffer, sizeof(buffer))) > 0) [data appendBytes:buffer length:count];
        if (data.length > 8192) Fail(@"代理参数过长。");
        input = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } else if (argc == 4 || argc == 5) {
        input = @{@"server": @(argv[2]), @"server_port": @(argv[3]), @"type": argc == 5 ? @(argv[4]) : @"http"};
    }
    if (![input isKindOfClass:NSDictionary.class]) Fail(@"代理参数必须为 JSON 对象。");
    NSString *ip = input[@"server"], *type = input[@"type"] ?: @"http";
    NSString *user = input[@"username"] ?: @"", *password = input[@"password"] ?: @"";
    id number = input[@"server_port"];
    if (![ip isKindOfClass:NSString.class] || ![type isKindOfClass:NSString.class] || ![user isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class] || (![number isKindOfClass:NSString.class] && ![number isKindOfClass:NSNumber.class])) Fail(@"代理参数类型不正确。");
    struct in_addr addr;
    if (inet_pton(AF_INET, ip.UTF8String, &addr) != 1 || !addr.s_addr || (ntohl(addr.s_addr) >> 28) >= 14) Fail(@"请输入有效的 IPv4 地址。");
    NSString *port = [number description];
    if (!port.length || [port rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound || port.integerValue < 1 || port.integerValue > 65535) Fail(@"端口必须为 1 到 65535。");
    if ((ntohl(addr.s_addr) >> 24) == 127 && port.integerValue == 9099) Fail(@"上游不能指向切换 API 自身。");
    if (![@[@"http", @"socks5"] containsObject:type]) Fail(@"代理类型必须为 http 或 socks5。");
    NSString *credentials = [user stringByAppendingString:password];
    if ([user lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 || [password lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 || (!user.length && password.length) || [credentials rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) Fail(@"代理账号密码无效。");
    return @{@"server": ip, @"server_port": @(port.integerValue), @"type": type, @"username": user, @"password": password,
             @"api_lan": @([input[@"api_lan"] boolValue])};
}
static BOOL Stop(void) {
    pid_t pid = RunningPID();
    NSDictionary *job = Launchctl(@[@"print", ServiceTarget()]);
    if ([job[@"code"] intValue] == 0) {
        NSDictionary *removed = Launchctl(@[@"bootout", ServiceTarget()]);
        if ([removed[@"code"] intValue] != 0) return NO;
    }
    if (!pid) return RestoreScopedRoutes();
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) return NO;
    for (int i = 0; i < 50; ++i) {
        if (RunningPID() != pid) { unlink(Path(@"pid").fileSystemRepresentation); usleep(500000); return RestoreScopedRoutes(); }
        usleep(100000);
    }
    return NO;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (setgid(0) != 0 || setuid(0) != 0) Fail(@"没有取得 root 权限，请确认使用 Dopamine RootHide 并重新安装安装包。");
        umask(0077);
        NSString *dir = StateDirectory();
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error]) Fail(error.localizedDescription);
        struct stat info;
        if (lstat(dir.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0077)) Fail(@"服务状态目录权限不正确。");
        int lock = open(Path(@"lock").fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (lock < 0 || flock(lock, LOCK_EX) != 0) Fail(@"无法锁定服务状态。");
        NSString *command = argc > 1 ? @(argv[1]) : @"status";
        if ([command isEqualToString:@"api-info"]) {
            NSString *secret = [NSString stringWithContentsOfFile:Path(@"api-token") encoding:NSUTF8StringEncoding error:nil] ?: @"";
            NSDictionary *config = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Path(@"config.json")] ?: [NSData data] options:0 error:nil];
            NSString *listen = config[@"outbounds"][1][@"api_listen"] ?: @"127.0.0.1:9099";
            NSString *host = @"127.0.0.1";
            if ([listen hasPrefix:@"0.0.0.0:"]) {
                struct ifaddrs *interfaces = NULL;
                if (!getifaddrs(&interfaces)) {
                    for (struct ifaddrs *it = interfaces; it; it = it->ifa_next) {
                        if (it->ifa_addr && it->ifa_addr->sa_family == AF_INET && !strcmp(it->ifa_name, "en0")) {
                            char value[INET_ADDRSTRLEN];
                            if (inet_ntop(AF_INET, &((struct sockaddr_in *)it->ifa_addr)->sin_addr, value, sizeof(value))) host = @(value);
                        }
                    }
                    freeifaddrs(interfaces);
                }
            }
            Reply(@{@"ok": @YES, @"token": secret, @"listen": listen, @"url": [NSString stringWithFormat:@"http://%@:9099/v1/proxy", host], @"message": secret.length ? @"API 密钥已就绪。" : @"启动新版服务后生成 API 密钥。"}, 0);
        }
        if ([command isEqualToString:@"status"]) {
            pid_t pid = RunningPID();
            NSDictionary *upstream = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Path(@"upstream.json")] ?: [NSData data] options:NSJSONReadingMutableContainers error:nil];
            NSMutableDictionary *publicUpstream = [upstream mutableCopy] ?: [NSMutableDictionary dictionary];
            [publicUpstream removeObjectForKey:@"password"];
            Reply(@{@"ok": @YES, @"running": @(pid != 0), @"pid": @(pid), @"upstream": publicUpstream, @"message": pid ? [NSString stringWithFormat:@"隧道运行中，PID=%d，上游 %@ %@:%@。", pid, publicUpstream[@"type"] ?: @"", publicUpstream[@"server"] ?: @"", publicUpstream[@"server_port"] ?: @""] : @"全局服务已停止。"}, 0);
        }
        if ([command isEqualToString:@"log"]) {
            NSString *log = [NSString stringWithContentsOfFile:Path(@"service.log") encoding:NSUTF8StringEncoding error:nil] ?: @"暂无日志。";
            if (log.length > 16000) log = [log substringFromIndex:log.length - 16000];
            NSRegularExpression *ansi = [NSRegularExpression regularExpressionWithPattern:@"\x1b\\[[0-9;]*m" options:0 error:nil];
            log = [ansi stringByReplacingMatchesInString:log options:0 range:NSMakeRange(0, log.length) withTemplate:@""];
            uint64_t rx = 0, tx = 0;
            BOOL present = TunCounters(&rx, &tx);
            NSString *state = [NSString stringWithFormat:@"\n当前诊断：utun99=%@，接收=%llu，发送=%llu\n", present ? @"存在" : @"不存在", (unsigned long long)rx, (unsigned long long)tx];
            Reply(@{@"ok": @YES, @"message": [log stringByAppendingString:state]}, 0);
        }
        if ([command isEqualToString:@"stop"]) {
            if (!Stop()) Fail(@"服务尚未退出，请稍后重试；未强行修改系统路由。");
            Reply(@{@"ok": @YES, @"message": @"服务已停止，隧道关闭。"}, 0);
        }
        BOOL switching = [command isEqualToString:@"switch"] || [command isEqualToString:@"switch-json"];
        if (!switching && ![command isEqualToString:@"start"] && ![command isEqualToString:@"start-json"]) Fail(@"用法：domainproxyctl start|switch IPv4 端口 [http|socks5] | start-json|switch-json（stdin JSON）| stop | status | log | api-info");
        NSDictionary *proxy = ProxyOptions(argc, argv, [command hasSuffix:@"-json"]);
        if (switching) {
            pid_t before = RunningPID();
            if (!before) Fail(@"服务未运行，请先启动全局服务。");
            NSMutableDictionary *body = [proxy mutableCopy];
            [body removeObjectForKey:@"api_lan"];
            body[@"close_existing"] = @YES;
            NSDictionary *result = ControlRequest(@"POST", body);
            if (![result[@"ok"] boolValue]) Fail(result[@"message"] ?: @"切换失败。");
            if (RunningPID() != before || [result[@"pid"] intValue] != before) Fail(@"核心 PID 发生变化，请刷新状态检查服务。");
            Reply(@{@"ok": @YES, @"pid": @(before), @"message": @"代理已切换，隧道服务未重启。旧代理连接已关闭，新连接使用新上游；代理可达性需联网验证。"}, 0);
        }
        NSData *templateData = [NSData dataWithContentsOfFile:jbroot(@"/Library/DomainProxy/global-config.json")];
        NSMutableDictionary *config = templateData ? [NSJSONSerialization JSONObjectWithData:templateData options:NSJSONReadingMutableContainers error:&error] : nil;
        if (!config) Fail(@"隧道规则文件缺失或损坏，请重新安装。");
        NSMutableDictionary *outbound = config[@"outbounds"][1];
        outbound[@"type"] = @"domainproxy";
        outbound[@"server"] = proxy[@"server"];
        outbound[@"server_port"] = proxy[@"server_port"];
        outbound[@"username"] = proxy[@"username"];
        outbound[@"password"] = proxy[@"password"];
        outbound[@"upstream_type"] = proxy[@"type"];
        outbound[@"api_listen"] = [proxy[@"api_lan"] boolValue] ? @"0.0.0.0:9099" : @"127.0.0.1:9099";
        NSString *secret = [NSString stringWithContentsOfFile:Path(@"api-token") encoding:NSUTF8StringEncoding error:nil];
        if (secret.length < 32) {
            secret = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByAppendingString:[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
            if (![secret writeToFile:Path(@"api-token") atomically:YES encoding:NSUTF8StringEncoding error:&error]) Fail(@"无法保存 API 密钥。");
        }
        outbound[@"api_secret"] = secret;
        outbound[@"state_path"] = Path(@"upstream.json");
        // Built-in HTTP/SOCKS dialers follow auto_detect_interface, including after a switch.
        [config[@"inbounds"][0] removeObjectForKey:@"route_exclude_address"];
        NSData *json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
        if (!json || ![json writeToFile:Path(@"config.json") options:NSDataWritingAtomic error:&error]) Fail(error.localizedDescription ?: @"写入规则失败。");
        if (!Stop()) Fail(@"旧服务没有退出，无法启动新服务。");
        NSDictionary *service = @{
            @"Label": @"local.domainproxy.tunnel",
            @"ProgramArguments": @[CorePath(), @"run", @"-c", Path(@"config.json")],
            @"UserName": @"root", @"RunAtLoad": @YES, @"KeepAlive": @NO,
            @"ProcessType": @"Background", @"ExitTimeOut": @5,
            @"EnvironmentVariables": @{@"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin", @"HOME": @"/var/root", @"GOMEMLIMIT": @"128MiB"},
            @"StandardOutPath": Path(@"service.log"), @"StandardErrorPath": Path(@"service.log")
        };
        if (![service writeToFile:Path(@"service.plist") atomically:YES]) Fail(@"写入后台服务定义失败。");
        if (![@"" writeToFile:Path(@"service.log") atomically:YES encoding:NSUTF8StringEncoding error:&error]) Fail(@"创建运行日志失败。");
        if (!PrepareScopedRoutes()) Fail(@"无法保留物理网络出站路由，未启动隧道。");
        NSDictionary *loaded = Launchctl(@[@"bootstrap", @"system", Path(@"service.plist")]);
        if ([loaded[@"code"] intValue]) { RestoreScopedRoutes(); Fail([NSString stringWithFormat:@"launchd 无法加载隧道服务：%@", loaded[@"output"]]); }
        pid_t pid = 0;
        for (int i = 0; i < 15 && !pid; ++i) { usleep(200000); pid = ServicePID(); }
        if (pid <= 1) {
            NSString *log = [NSString stringWithContentsOfFile:Path(@"service.log") encoding:NSUTF8StringEncoding error:nil];
            Launchctl(@[@"bootout", ServiceTarget()]);
            RestoreScopedRoutes();
            Fail([NSString stringWithFormat:@"后台服务没有启动：%@", log ?: @"请查看日志"]);
        }
        if (!SetCoreMemoryBudget(pid)) {
            Launchctl(@[@"bootout", ServiceTarget()]);
            RestoreScopedRoutes();
            Fail(@"无法设置核心后台内存限额，已停止，避免运行后被系统终止。");
        }
        NSString *pidText = [NSString stringWithFormat:@"%d", pid];
        if (![pidText writeToFile:Path(@"pid") atomically:YES encoding:NSUTF8StringEncoding error:&error]) { Launchctl(@[@"bootout", ServiceTarget()]); RestoreScopedRoutes(); Fail(@"记录服务状态失败。"); }
        usleep(800000);
        if (RunningPID() != pid) {
            Launchctl(@[@"bootout", ServiceTarget()]);
            RestoreScopedRoutes();
            NSString *log = [NSString stringWithContentsOfFile:Path(@"service.log") encoding:NSUTF8StringEncoding error:nil];
            Fail(log.length ? log : @"隧道核心启动后退出，请查看日志。");
        }
        NSString *diagnostic = nil;
        BOOL healthy = ForwardingProbe(&diagnostic);
        AppendLog(diagnostic);
        if (!healthy) {
            BOOL stopped = Stop();
            Fail([NSString stringWithFormat:@"转发自检未通过，%@。%@ 请查看运行日志。", stopped ? @"已自动停止并关闭隧道" : @"自动停止失败，请点停止；必要时重启手机恢复网络", diagnostic]);
        }
        Reply(@{@"ok": @YES, @"running": @YES, @"message": @"后台服务已启动，DNS 与隧道双向收发自检通过。请继续验证 ip138.com 出口和切换 App 后的网络。"}, 0);
    }
}
