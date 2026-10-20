#import <UIKit/UIKit.h>
#import <roothide.h>
#include <arpa/inet.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
extern char **environ;

@interface ProxyController : UIViewController <NSURLSessionDelegate>
@property(nonatomic, strong) UITextField *ipField;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UITextField *apiField;
@property(nonatomic, strong) UITextField *usernameField;
@property(nonatomic, strong) UITextField *passwordField;
@property(nonatomic, strong) UISegmentedControl *protocolControl;
@property(nonatomic, strong) UISwitch *lanSwitch;
@property(nonatomic, strong) UIButton *apiButton;
@property(nonatomic, strong) UILabel *apiStatusLabel;
@property(nonatomic) BOOL fetching;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@property(nonatomic) BOOL busy;
@end

@implementation ProxyController
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new];
    label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}
- (UITextField *)field:(NSString *)hint keyboard:(UIKeyboardType)keyboard {
    UITextField *field = [UITextField new];
    field.placeholder = hint; field.keyboardType = keyboard;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return field;
}
- (UIButton *)button:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = primary ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
    config.title = title; config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = config;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.buttons addObject:button];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"全局域名代理";
    self.buttons = [NSMutableArray new];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成输入" style:UIBarButtonItemStylePlain target:self action:@selector(dismissKeyboard)];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    [stack addArrangedSubview:[self label:@"HTTP / SOCKS5 上游代理" style:UIFontTextStyleTitle1]];
    [stack addArrangedSubview:[self label:@"以下域名及其全部子域名走代理：\nzijieapi.com\nfqnovel.com\nip138.com\n\n其余 IPv4 流量直连。隧道内 IPv6 流量被拦截。" style:UIFontTextStyleBody]];
    [stack addArrangedSubview:[self label:@"取代理 API 地址" style:UIFontTextStyleHeadline]];
    self.apiField = [self field:@"https://example.com/getproxy" keyboard:UIKeyboardTypeURL];
    self.apiField.accessibilityLabel = @"取代理 API 地址";
    [stack addArrangedSubview:self.apiField];
    self.apiButton = [self button:@"获取并填入 IP 和端口" action:@selector(fetchProxy) primary:NO];
    [stack addArrangedSubview:self.apiButton];
    self.apiStatusLabel = [self label:@"" style:UIFontTextStyleFootnote];
    self.apiStatusLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.apiStatusLabel];
    [stack addArrangedSubview:[self label:@"支持纯文本 IPv4:端口（例如 127.0.0.1:8888）或包含 ip、port 的 JSON。获取后点击下方保存并启动即可应用。" style:UIFontTextStyleFootnote]];
    [stack addArrangedSubview:[self label:@"代理 IPv4 地址" style:UIFontTextStyleHeadline]];
    self.ipField = [self field:@"例如 192.168.1.10" keyboard:UIKeyboardTypeDecimalPad];
    self.ipField.accessibilityLabel = @"代理 IPv4 地址";
    [stack addArrangedSubview:self.ipField];
    [stack addArrangedSubview:[self label:@"代理端口" style:UIFontTextStyleHeadline]];
    self.portField = [self field:@"例如 8080" keyboard:UIKeyboardTypeNumberPad];
    self.portField.accessibilityLabel = @"代理端口";
    [stack addArrangedSubview:self.portField];
    self.protocolControl = [[UISegmentedControl alloc] initWithItems:@[@"HTTP", @"SOCKS5"]];
    self.protocolControl.accessibilityLabel = @"上游代理协议";
    [stack addArrangedSubview:self.protocolControl];
    self.usernameField = [self field:@"代理账号（无认证时留空）" keyboard:UIKeyboardTypeDefault];
    self.usernameField.accessibilityLabel = @"代理账号";
    [stack addArrangedSubview:self.usernameField];
    self.passwordField = [self field:@"代理密码（无认证时留空）" keyboard:UIKeyboardTypeDefault];
    self.passwordField.secureTextEntry = YES;
    self.passwordField.accessibilityLabel = @"代理密码";
    [stack addArrangedSubview:self.passwordField];
    [stack addArrangedSubview:[self button:@"保存并启动全局代理" action:@selector(start) primary:YES]];
    [stack addArrangedSubview:[self button:@"切换代理（不重启服务）" action:@selector(switchProxy) primary:YES]];
    [stack addArrangedSubview:[self label:@"切换会断开旧代理连接，新连接走新上游；隧道与直连连接保持运行。更换协议和账号密码也无需重启。" style:UIFontTextStyleFootnote]];
    [stack addArrangedSubview:[self label:@"后台 HTTP 切换 API" style:UIFontTextStyleHeadline]];
    [stack addArrangedSubview:[self label:@"允许局域网调用（启动服务时应用）" style:UIFontTextStyleBody]];
    self.lanSwitch = [UISwitch new];
    self.lanSwitch.accessibilityLabel = @"允许局域网调用切换 API";
    [stack addArrangedSubview:self.lanSwitch];
    [stack addArrangedSubview:[self button:@"查看并复制 API 调用示例" action:@selector(showAPI) primary:NO]];
    [stack addArrangedSubview:[self label:@"接口在隧道核心内运行，App 退到后台或关闭后仍可调用。端口 9099，必须带独立密钥；HTTP 明文接口仅在可信局域网使用。关闭局域网调用时，仅手机本机可访问。" style:UIFontTextStyleFootnote]];
    [stack addArrangedSubview:[self button:@"停止全局代理" action:@selector(stop) primary:NO]];
    [stack addArrangedSubview:[self button:@"刷新服务状态" action:@selector(refresh) primary:NO]];
    [stack addArrangedSubview:[self button:@"查看运行日志" action:@selector(log) primary:NO]];
    self.statusLabel = [self label:@"正在读取服务状态…" style:UIFontTextStyleFootnote];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.statusLabel];
    UILabel *note = [self label:@"适用于 iOS 16.1 Dopamine RootHide，无需为目标 App 开启注入。支持 HTTP / SOCKS5 和可选账号密码；目标域名 UDP 仍被拒绝。\n\n首次启动请先关闭其他 VPN。启动后会检查 DNS 和隧道双向收发，不通过则自动停止。\n\n切换上游无需重启；Wi-Fi/蜂窝网络切换异常时，请停止后重新启动。\n\n启动自检不能保证所有 App 都被接管。停止服务后恢复系统网络，不提供断线锁网。" style:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:note];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.ipField.text = [defaults stringForKey:@"ProxyIP"] ?: @"";
    self.portField.text = [defaults stringForKey:@"ProxyPort"] ?: @"8080";
    self.apiField.text = [defaults stringForKey:@"ProxyAPIURL"] ?: @"";
    self.protocolControl.selectedSegmentIndex = [[defaults stringForKey:@"ProxyType"] isEqualToString:@"socks5"] ? 1 : 0;
    self.usernameField.text = [defaults stringForKey:@"ProxyUsername"] ?: @"";
    self.passwordField.text = [defaults stringForKey:@"ProxyPassword"] ?: @"";
    self.lanSwitch.on = [defaults objectForKey:@"ProxyAPILAN"] ? [defaults boolForKey:@"ProxyAPILAN"] : YES;
    [self.apiField addTarget:self action:@selector(saveAPIURL) forControlEvents:UIControlEventEditingDidEnd];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self refresh]; }
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (void)saveAPIURL {
    NSString *value = [self.apiField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSUserDefaults.standardUserDefaults setObject:value ?: @"" forKey:@"ProxyAPIURL"];
}
// Accept one validated endpoint from plain text or common API JSON envelopes.
- (NSArray<NSString *> *)proxyEndpointFromValue:(id)value depth:(NSUInteger)depth {
    if (!value || depth > 6) return nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        id ip = value[@"ip"] ?: value[@"host"] ?: value[@"server"];
        id port = value[@"port"];
        if ([ip isKindOfClass:NSString.class] &&
            ([port isKindOfClass:NSString.class] || [port isKindOfClass:NSNumber.class])) {
            NSArray *endpoint = [self proxyEndpointFromValue:[NSString stringWithFormat:@"%@:%@", ip, port] depth:depth + 1];
            if (endpoint) return endpoint;
        }
        for (NSString *key in @[@"data", @"result", @"list", @"proxies", @"proxy", @"proxy_list"] ) {
            NSArray *endpoint = [self proxyEndpointFromValue:value[key] depth:depth + 1];
            if (endpoint) return endpoint;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) {
            NSArray *endpoint = [self proxyEndpointFromValue:item depth:depth + 1];
            if (endpoint) return endpoint;
        }
    } else if ([value isKindOfClass:NSString.class]) {
        NSString *body = [value stringByReplacingOccurrencesOfString:@"\uFEFF" withString:@""];
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"\\A\\s*([0-9]{1,3}(?:\\.[0-9]{1,3}){3})\\s*:\\s*([0-9]{1,5})\\s*\\z" options:0 error:nil];
        NSTextCheckingResult *match = [pattern firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
        if (match) {
            NSString *ip = [body substringWithRange:[match rangeAtIndex:1]];
            NSInteger port = [[body substringWithRange:[match rangeAtIndex:2]] integerValue];
            struct in_addr address;
            if (inet_pton(AF_INET, ip.UTF8String, &address) == 1 && port >= 1 && port <= 65535)
                return @[ip, [NSString stringWithFormat:@"%ld", (long)port]];
        }
    }
    return nil;
}
- (void)fetchProxy {
    if (self.fetching) return;
    [self dismissKeyboard];
    [self saveAPIURL];
    NSURL *url = [NSURL URLWithString:[NSUserDefaults.standardUserDefaults stringForKey:@"ProxyAPIURL"]];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length || (! [scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
        self.apiStatusLabel.text = @"请输入完整的 http:// 或 https:// API 地址。";
        return;
    }
    self.fetching = YES; self.apiButton.enabled = NO;
    self.apiStatusLabel.text = @"正在获取代理…（最多等待 20 秒）";
    UIButtonConfiguration *loading = [self.apiButton.configuration copy];
    loading.title = @"正在获取…"; loading.showsActivityIndicator = YES;
    self.apiButton.configuration = loading;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 15;
    configuration.timeoutIntervalForResource = 20;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.waitsForConnectivity = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *message = nil, *ip = nil, *port = nil;
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        if (error.code == NSURLErrorNotConnectedToInternet) message = @"获取失败（-1009）：当前网络不可用或系统未允许本 App 联网。请检查“域名代理”的无线局域网/蜂窝数据权限后重试。";
        else if (error) message = [NSString stringWithFormat:@"获取失败：%@（错误码 %ld）。", error.localizedDescription, (long)error.code];
        else if (code < 200 || code >= 300) message = [NSString stringWithFormat:@"接口返回 HTTP %ld，未修改代理设置。", (long)code];
        else if (!data.length || data.length > 16384) message = @"接口返回为空或过长，请确认返回一条 IPv4:端口。";
        else {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            body = [body stringByReplacingOccurrencesOfString:@"\uFEFF" withString:@""];
            id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
            NSArray *endpoint = [self proxyEndpointFromValue:json ?: body depth:0];
            if (endpoint) { ip = endpoint[0]; port = endpoint[1]; }
            if (!ip) message = @"接口未返回有效代理。支持 IPv4:端口，或包含 ip/port 的 JSON；请检查接口是否返回了鉴权、白名单或余额错误。";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.fetching = NO; self.apiButton.enabled = YES;
            UIButtonConfiguration *finished = [self.apiButton.configuration copy];
            finished.title = @"获取并填入 IP 和端口"; finished.showsActivityIndicator = NO;
            self.apiButton.configuration = finished;
            if (ip) {
                self.ipField.text = ip; self.portField.text = port;
                [NSUserDefaults.standardUserDefaults setObject:ip forKey:@"ProxyIP"];
                [NSUserDefaults.standardUserDefaults setObject:port forKey:@"ProxyPort"];
                self.apiStatusLabel.text = [NSString stringWithFormat:@"已填入 %@:%@；服务运行中点“切换代理”，未运行时点“保存并启动”。", ip, port];
            } else self.apiStatusLabel.text = message;
        });
        [session finishTasksAndInvalidate];
    }] resume];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // User-requested certificate bypass applies only to the dedicated API session.
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] && challenge.protectionSpace.serverTrust) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
- (void)run:(NSString *)command arguments:(NSArray<NSString *> *)arguments {
    [self run:command arguments:arguments input:nil];
}
- (void)run:(NSString *)command arguments:(NSArray<NSString *> *)arguments input:(NSData *)input {
    if (self.busy) return;
    self.busy = YES;
    for (UIButton *button in self.buttons) button.enabled = button == self.apiButton && !self.fetching;
    self.statusLabel.text = @"正在处理…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *helper = jbroot(@"/usr/bin/domainproxyctl");
        NSString *inputPath = input ? [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] : nil;
        if (input && ![input writeToFile:inputPath options:NSDataWritingAtomic error:nil]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                for (UIButton *button in self.buttons) button.enabled = button != self.apiButton || !self.fetching;
                self.statusLabel.text = @"无法准备代理参数，请重试。";
            });
            return;
        }
        if (inputPath) chmod(inputPath.fileSystemRepresentation, 0600);
        NSArray<NSString *> *all = [@[helper, command] arrayByAddingObjectsFromArray:arguments];
        char **args = (char **)calloc(all.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < all.count; ++i) args[i] = strdup(all[i].UTF8String);
        int pipes[2];
        NSMutableData *output = [NSMutableData new];
        int result = pipe(pipes);
        if (result == 0) {
            posix_spawn_file_actions_t actions;
            posix_spawn_file_actions_init(&actions);
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, inputPath ? inputPath.fileSystemRepresentation : "/dev/null", O_RDONLY, 0);
            posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
            posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
            posix_spawn_file_actions_addclose(&actions, pipes[0]);
            posix_spawn_file_actions_addclose(&actions, pipes[1]);
            pid_t pid = 0;
            result = posix_spawn(&pid, helper.fileSystemRepresentation, &actions, NULL, args, environ);
            posix_spawn_file_actions_destroy(&actions);
            close(pipes[1]);
            if (result == 0) {
                char buffer[4096]; ssize_t size;
                while ((size = read(pipes[0], buffer, sizeof(buffer))) > 0) [output appendBytes:buffer length:size];
                int status; waitpid(pid, &status, 0);
            }
            close(pipes[0]);
        } else { result = errno; }
        for (NSUInteger i = 0; i < all.count; ++i) free(args[i]);
        free(args);
        if (inputPath) [NSFileManager.defaultManager removeItemAtPath:inputPath error:nil];
        NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:output options:0 error:nil];
        NSString *message = reply[@"message"];
        if (!message) message = result ? [NSString stringWithFormat:@"无法运行服务控制器：%s。请确认越狱已启用并重新安装。", strerror(result)] : [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        if (!message.length) message = @"服务控制器没有返回结果，请重新安装并确认越狱状态。";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            for (UIButton *button in self.buttons) button.enabled = button != self.apiButton || !self.fetching;
            self.statusLabel.text = message;
            if ([command isEqualToString:@"api-info"] && [reply[@"ok"] boolValue]) {
                NSString *token = reply[@"token"];
                if (token.length) {
                    NSString *url = reply[@"url"] ?: @"http://127.0.0.1:9099/v1/proxy";
                    NSString *example = [NSString stringWithFormat:@"curl -X POST '%@' -H 'Authorization: Bearer %@' -H 'Content-Type: application/json' -d '{\"type\":\"%@\",\"ip\":\"192.0.2.10\",\"port\":8080,\"username\":\"\",\"password\":\"\",\"close_existing\":true}'", url, token, self.protocolControl.selectedSegmentIndex == 1 ? @"socks5" : @"http"];
                    UIPasteboard.generalPasteboard.string = example;
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已复制 API 调用示例" message:[NSString stringWithFormat:@"地址：%@\n本机：http://127.0.0.1:9099/v1/proxy\n\n把示例 IP、端口和账号密码换成你的代理。type 支持 http、socks5。GET 同一地址可查看当前上游和 PID。\n\n服务必须正在运行，App 无需在前台。密钥已包含在剪贴板示例中，请妥善保管。", url] preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                }
            }
            if ([command isEqualToString:@"log"]) {
                UIViewController *viewer = [UIViewController new];
                viewer.title = @"运行日志";
                UITextView *text = [[UITextView alloc] initWithFrame:CGRectZero];
                text.editable = NO; text.text = message;
                text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
                text.backgroundColor = UIColor.systemBackgroundColor;
                viewer.view = text;
                [self.navigationController pushViewController:viewer animated:YES];
            }
        });
    });
}
- (void)applyProxy:(NSString *)command {
    [self dismissKeyboard];
    NSString *ip = [self.ipField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *port = [self.portField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    struct in_addr address;
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (inet_pton(AF_INET, ip.UTF8String, &address) != 1 || !port.length || [port rangeOfCharacterFromSet:nonDigits].location != NSNotFound || port.integerValue < 1 || port.integerValue > 65535) {
        self.statusLabel.text = @"请输入有效的 IPv4 地址和 1 到 65535 之间的端口。";
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:ip forKey:@"ProxyIP"];
    [NSUserDefaults.standardUserDefaults setObject:port forKey:@"ProxyPort"];
    NSString *type = self.protocolControl.selectedSegmentIndex == 1 ? @"socks5" : @"http";
    [NSUserDefaults.standardUserDefaults setObject:type forKey:@"ProxyType"];
    [NSUserDefaults.standardUserDefaults setObject:self.usernameField.text ?: @"" forKey:@"ProxyUsername"];
    [NSUserDefaults.standardUserDefaults setObject:self.passwordField.text ?: @"" forKey:@"ProxyPassword"];
    [NSUserDefaults.standardUserDefaults setBool:self.lanSwitch.on forKey:@"ProxyAPILAN"];
    NSDictionary *body = @{@"type": type, @"server": ip, @"server_port": @(port.integerValue), @"username": self.usernameField.text ?: @"", @"password": self.passwordField.text ?: @"", @"api_lan": @(self.lanSwitch.on)};
    [self run:command arguments:@[] input:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
}
- (void)start { [self applyProxy:@"start-json"]; }
- (void)switchProxy { [self applyProxy:@"switch-json"]; }
- (void)showAPI { [self run:@"api-info" arguments:@[]]; }
- (void)stop { [self run:@"stop" arguments:@[]]; }
- (void)refresh { [self run:@"status" arguments:@[]]; }
- (void)log { [self run:@"log" arguments:@[]]; }
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[ProxyController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
