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
extern char **environ;
extern "C" int proc_pidpath(int, void *, uint32_t);

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
static pid_t RunningPID(void) {
    pid_t pid = [[NSString stringWithContentsOfFile:Path(@"pid") encoding:NSUTF8StringEncoding error:nil] intValue];
    if (pid <= 1 || kill(pid, 0) != 0) return 0;
    char actual[4096] = {}, expected[4096] = {}, resolved[4096] = {};
    if (proc_pidpath(pid, actual, sizeof(actual)) <= 0) return 0;
    if (!realpath(CorePath().fileSystemRepresentation, expected)) return 0;
    if (!realpath(actual, resolved)) return 0;
    return strcmp(expected, resolved) == 0 ? pid : 0;
}
static BOOL Stop(void) {
    pid_t pid = RunningPID();
    if (!pid) return YES;
    if (kill(pid, SIGTERM) != 0) return NO;
    for (int i = 0; i < 50; ++i) {
        if (RunningPID() != pid) { unlink(Path(@"pid").fileSystemRepresentation); return YES; }
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
        if ([command isEqualToString:@"status"]) {
            pid_t pid = RunningPID();
            Reply(@{@"ok": @YES, @"running": @(pid != 0), @"pid": @(pid), @"message": pid ? @"隧道进程运行中，实际分流效果需联网验证。" : @"全局服务已停止。"}, 0);
        }
        if ([command isEqualToString:@"log"]) {
            NSString *log = [NSString stringWithContentsOfFile:Path(@"service.log") encoding:NSUTF8StringEncoding error:nil] ?: @"暂无日志。";
            if (log.length > 16000) log = [log substringFromIndex:log.length - 16000];
            Reply(@{@"ok": @YES, @"message": log}, 0);
        }
        if ([command isEqualToString:@"stop"]) {
            if (!Stop()) Fail(@"服务尚未退出，请稍后重试；未强行修改系统路由。");
            Reply(@{@"ok": @YES, @"message": @"服务已停止，隧道关闭。"}, 0);
        }
        if (![command isEqualToString:@"start"] || argc != 4) Fail(@"用法：domainproxyctl start IPv4 端口 | stop | status | log");
        struct in_addr addr;
        if (inet_pton(AF_INET, argv[2], &addr) != 1) Fail(@"请输入有效的 IPv4 地址。");
        char *end = NULL;
        long port = strtol(argv[3], &end, 10);
        if (!argv[3][0] || *end || port < 1 || port > 65535) Fail(@"端口必须为 1 到 65535。");
        NSData *templateData = [NSData dataWithContentsOfFile:jbroot(@"/Library/DomainProxy/global-config.json")];
        NSMutableDictionary *config = templateData ? [NSJSONSerialization JSONObjectWithData:templateData options:NSJSONReadingMutableContainers error:&error] : nil;
        if (!config) Fail(@"隧道规则文件缺失或损坏，请重新安装。");
        config[@"outbounds"][1][@"server"] = @(argv[2]);
        config[@"outbounds"][1][@"server_port"] = @(port);
        config[@"inbounds"][0][@"route_exclude_address"] = @[[NSString stringWithFormat:@"%s/32", argv[2]]];
        NSData *json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
        if (!json || ![json writeToFile:Path(@"config.json") options:NSDataWritingAtomic error:&error]) Fail(error.localizedDescription ?: @"写入规则失败。");
        if (!Stop()) Fail(@"旧服务没有退出，无法启动新服务。");
        NSString *core = CorePath();
        NSString *configPath = Path(@"config.json");
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, Path(@"service.log").fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
        char *args[] = {(char *)core.fileSystemRepresentation, (char *)"run", (char *)"-c", (char *)configPath.fileSystemRepresentation, NULL};
        // Keep the child environment minimal; never pass caller-controlled loader variables to root.
        char *childEnv[] = {(char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin", (char *)"HOME=/var/root", NULL};
        pid_t pid = 0;
        int result = posix_spawn(&pid, core.fileSystemRepresentation, &actions, NULL, args, childEnv);
        posix_spawn_file_actions_destroy(&actions);
        if (result) Fail([NSString stringWithFormat:@"无法启动隧道核心：%s", strerror(result)]);
        NSString *pidText = [NSString stringWithFormat:@"%d", pid];
        if (![pidText writeToFile:Path(@"pid") atomically:YES encoding:NSUTF8StringEncoding error:&error]) { kill(pid, SIGTERM); Fail(@"记录服务状态失败。"); }
        usleep(800000);
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid || RunningPID() != pid) {
            // A child whose identity cannot be verified must never be left running.
            if (waited != pid) kill(pid, SIGTERM);
            NSString *log = [NSString stringWithContentsOfFile:Path(@"service.log") encoding:NSUTF8StringEncoding error:nil];
            Fail(log.length ? log : @"隧道核心启动后退出，请查看日志。");
        }
        Reply(@{@"ok": @YES, @"running": @YES, @"message": @"隧道进程已启动。请测试 ip138.com 的出口 IP 和 IPv6；进程运行不等于流量已全部接管。"}, 0);
    }
}
